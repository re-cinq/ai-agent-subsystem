#!/usr/bin/env node
// One-file listener for an AgentDefinition `output` http sink. Zero dependencies —
// just node:http. Prints every POSTed event to the screen.
//
//   node examples/notify-listener.mjs [port]      # default 8099, or PORT env
//
// Point a recipe's http sink at this listener and every stream-json event the run
// emits is POSTed here (one POST per event). On minikube the host is reachable from
// the cluster at http://host.minikube.internal:8099/notify. GET /healthz -> ok.
//
// It understands this project's AgentEvent shape ({event:{type,text}}) and Claude's
// stream-json events ({type:"assistant"|"tool_use"|"result"|...}).
import { createServer } from "node:http";

const PORT = Number(process.argv[2] || process.env.PORT || 8099);
const firstLine = (s) => String(s ?? "").split("\n")[0].slice(0, 200);

function summarize(item) {
  if (!item || typeof item !== "object") return "(notification)";

  // Claude Code stream-json events
  if (item.type === "system") return `[system:${item.subtype ?? "?"}]`;
  if (item.type === "assistant" && Array.isArray(item.message?.content)) {
    return (
      item.message.content
        .map((b) =>
          b.type === "text"
            ? `text: ${firstLine(b.text)}`
            : b.type === "tool_use"
              ? `tool_use ${b.name}(${Object.keys(b.input ?? {}).join(",")})`
              : b.type,
        )
        .join("  |  ") || "[assistant]"
    );
  }
  if (item.type === "user" && Array.isArray(item.message?.content)) {
    return item.message.content.map((b) => (b.type === "tool_result" ? "tool_result" : b.type)).join("  |  ");
  }
  if (item.type === "result") {
    const cost = item.total_cost_usd != null ? `  ($${item.total_cost_usd})` : "";
    return `[result] ${firstLine(item.result)}${cost}`;
  }

  // This project's AgentEvent shape: {event:{type,text}, source:{...}}
  const ev = item.event ?? item;
  const kind = ev?.type ?? ev?.kind;
  if (kind) return `[${kind}] ${firstLine(ev.text)}`;
  return "(notification)";
}

function printNotification(path, raw) {
  const ts = new Date().toISOString();
  const items = [];
  const trimmed = raw.trim();
  if (trimmed) {
    try {
      items.push(JSON.parse(trimmed)); // a single JSON object
    } catch {
      for (const line of trimmed.split("\n")) {
        // tolerate NDJSON / stream-json
        const l = line.trim();
        if (!l) continue;
        try {
          items.push(JSON.parse(l));
        } catch {
          items.push(l);
        }
      }
    }
  } else {
    items.push("(empty body)");
  }

  for (const item of items) {
    console.log(`\n-- ${ts}  POST ${path}  ${summarize(item)}`);
    console.log(typeof item === "string" ? item : JSON.stringify(item, null, 2));
  }
}

const server = createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok");
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(405, { "content-type": "text/plain" });
    res.end("POST a notification, or GET /healthz\n");
    return;
  }
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
  });
  req.on("end", () => {
    try {
      printNotification(req.url || "/", body);
    } catch (err) {
      console.error("print error:", err);
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"ok":true}');
  });
});

server.on("error", (err) => {
  console.error(`[notify-listener] error: ${err.message}`);
  process.exit(1);
});
server.listen(PORT, () => console.log(`[notify-listener] listening on :${PORT}  (POST any path; GET /healthz)`));
