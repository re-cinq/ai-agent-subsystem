//! An in-memory Kubernetes API server for the tests: a tower service that `kube::Client` sends
//! its real requests to. It stores objects by path and records every PATCH.

use std::collections::BTreeMap;
use std::convert::Infallible;
use std::sync::{Arc, Mutex};

use http::{Request, Response, StatusCode};
use kube::Client;
use kube::client::Body;
use serde_json::{Value, json};

#[derive(Clone, Debug)]
pub struct RecordedPatch {
    pub path_and_query: String,
    pub content_type: String,
    pub body: Value,
}

#[derive(Default)]
pub struct State {
    pub objects: BTreeMap<String, Value>,
    pub patches: Vec<RecordedPatch>,
    generated: u32,
}

pub type Store = Arc<Mutex<State>>;

pub fn fake_client() -> (Client, Store) {
    let store = Store::default();
    let shared = store.clone();
    let service = tower::service_fn(move |request: Request<Body>| {
        let store = shared.clone();
        async move { Ok::<_, Infallible>(handle(&store, request).await) }
    });
    (Client::new(service, "default"), store)
}

async fn handle(store: &Store, request: Request<Body>) -> Response<Body> {
    let method = request.method().clone();
    let path = request.uri().path().to_string();
    let query = request.uri().query().unwrap_or_default().to_string();
    let content_type = request
        .headers()
        .get("content-type")
        .map(|value| value.to_str().unwrap().to_string())
        .unwrap_or_default();
    let bytes = request.into_body().collect_bytes().await.unwrap();
    let body: Value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap()
    };
    let mut state = store.lock().unwrap();
    match method.as_str() {
        "POST" => {
            let mut stored = body;
            if stored["metadata"]["name"].is_null() {
                state.generated += 1;
                let name = format!(
                    "{}{}",
                    stored["metadata"]["generateName"].as_str().unwrap(),
                    state.generated
                );
                stored["metadata"]["name"] = json!(name);
            }
            let key = format!("{path}/{}", stored["metadata"]["name"].as_str().unwrap());
            state.objects.insert(key, stored.clone());
            reply(StatusCode::CREATED, &stored)
        }
        "GET" if state.objects.contains_key(&path) => reply(StatusCode::OK, &state.objects[&path]),
        "GET" if query.contains("labelSelector") => {
            let selector = query
                .split('&')
                .find_map(|pair| pair.strip_prefix("labelSelector="))
                .unwrap();
            let (key, value) = selector.split_once("%3D").unwrap();
            let items: Vec<Value> = state
                .objects
                .iter()
                .filter(|(stored_path, stored)| {
                    stored_path.starts_with(&format!("{path}/"))
                        && stored["metadata"]["labels"][key] == json!(value)
                })
                .map(|(_, stored)| stored.clone())
                .collect();
            reply(
                StatusCode::OK,
                &json!({"apiVersion": "agents.re-cinq.com/v1beta1", "kind": "AgentList",
                "metadata": {}, "items": items}),
            )
        }
        "PATCH" => {
            state.patches.push(RecordedPatch {
                path_and_query: format!("{path}?{query}"),
                content_type,
                body: body.clone(),
            });
            state.objects.insert(path, body.clone());
            reply(StatusCode::OK, &body)
        }
        _ => reply(
            StatusCode::NOT_FOUND,
            &json!({"kind": "Status", "apiVersion": "v1", "metadata": {},
            "status": "Failure", "message": format!("{path} not found"), "reason": "NotFound", "code": 404}),
        ),
    }
}

fn reply(status: StatusCode, body: &Value) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(body).unwrap()))
        .unwrap()
}
