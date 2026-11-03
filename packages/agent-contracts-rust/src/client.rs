use std::fmt::{self, Debug, Display};
use std::time::Duration;

use kube::api::{ListParams, Patch, PatchParams, PostParams};
use kube::core::NamespaceResourceScope;
use kube::{Api, Client, Resource};
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::types::{Agent, AgentDefinition, ModelCatalog, Phase, Station};

/// The namespace the subsystem installs into and runs Agents in.
pub const DEFAULT_NAMESPACE: &str = "ai-agents";

const FIELD_MANAGER: &str = "agent-contracts";
const MODEL_CATALOG_NAME: &str = "default";

/// What a client call can fail with.
#[derive(Debug)]
pub enum Error {
    /// The Kubernetes API rejected the call or could not be reached.
    Kube(kube::Error),
    /// A resource to apply has no `metadata.name`; the value is its kind.
    MissingName(String),
}

impl Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Kube(error) => write!(formatter, "{error}"),
            Self::MissingName(kind) => write!(formatter, "apply {kind}: metadata.name is required"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Kube(error) => Some(error),
            Self::MissingName(_) => None,
        }
    }
}

impl From<kube::Error> for Error {
    fn from(error: kube::Error) -> Self {
        Self::Kube(error)
    }
}

/// Whether a run has finished (Succeeded or Failed).
pub fn is_terminal(agent: &Agent) -> bool {
    let phase = agent.status.as_ref().and_then(|status| status.phase);
    matches!(phase, Some(Phase::Succeeded | Phase::Failed))
}

/// Creates and reads the subsystem's resources in one namespace through a [`kube::Client`].
#[derive(Clone)]
pub struct AgentContractsClient {
    kube: Client,
    namespace: String,
}

impl AgentContractsClient {
    /// A client for `namespace`, or [`DEFAULT_NAMESPACE`] when it is empty.
    pub fn new(kube: Client, namespace: &str) -> Self {
        let namespace = if namespace.is_empty() {
            DEFAULT_NAMESPACE
        } else {
            namespace
        };
        Self {
            kube,
            namespace: namespace.to_string(),
        }
    }

    fn api<K>(&self) -> Api<K>
    where
        K: Resource<Scope = NamespaceResourceScope, DynamicType = ()>,
    {
        Api::namespaced(self.kube.clone(), &self.namespace)
    }

    /// Starts one run in the client's namespace.
    pub async fn create_agent(&self, agent: &Agent) -> Result<Agent, Error> {
        let mut agent = agent.clone();
        agent.metadata.namespace = Some(self.namespace.clone());
        Ok(self
            .api::<Agent>()
            .create(&PostParams::default(), &agent)
            .await?)
    }

    /// Reads one run.
    pub async fn get_agent(&self, name: &str) -> Result<Agent, Error> {
        Ok(self.api::<Agent>().get(name).await?)
    }

    /// Lists the runs matching a Kubernetes label selector such as `team=web`.
    pub async fn find_agents(&self, label_selector: &str) -> Result<Vec<Agent>, Error> {
        let listed = self
            .api::<Agent>()
            .list(&ListParams::default().labels(label_selector))
            .await?;
        Ok(listed.items)
    }

    /// Reads the models the subsystem can run (the controller's `default` ModelCatalog).
    pub async fn get_model_catalog(&self) -> Result<ModelCatalog, Error> {
        Ok(self.api::<ModelCatalog>().get(MODEL_CATALOG_NAME).await?)
    }

    /// Server-side applies an AgentDefinition, taking over fields other managers set.
    pub async fn apply_agent_definition(
        &self,
        definition: &AgentDefinition,
    ) -> Result<AgentDefinition, Error> {
        self.apply(definition).await
    }

    /// Server-side applies a Station, taking over fields other managers set.
    pub async fn apply_station(&self, station: &Station) -> Result<Station, Error> {
        self.apply(station).await
    }

    async fn apply<K>(&self, resource: &K) -> Result<K, Error>
    where
        K: Resource<Scope = NamespaceResourceScope, DynamicType = ()>
            + Clone
            + Debug
            + Serialize
            + DeserializeOwned,
    {
        let name = resource.meta().name.clone().filter(|name| !name.is_empty());
        let name = name.ok_or_else(|| Error::MissingName(K::kind(&()).to_string()))?;
        let mut resource = resource.clone();
        resource.meta_mut().namespace = Some(self.namespace.clone());
        resource.meta_mut().managed_fields = None;
        let params = PatchParams::apply(FIELD_MANAGER).force();
        Ok(self
            .api::<K>()
            .patch(&name, &params, &Patch::Apply(&resource))
            .await?)
    }

    /// Polls the run every `interval` until it is Succeeded or Failed. It never gives up on its
    /// own: wrap it in [`tokio::time::timeout`] to bound the wait.
    pub async fn wait_for_agent(&self, name: &str, interval: Duration) -> Result<Agent, Error> {
        loop {
            let agent = self.get_agent(name).await?;
            if is_terminal(&agent) {
                return Ok(agent);
            }
            tokio::time::sleep(interval).await;
        }
    }
}
