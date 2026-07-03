import { describe, it, expect } from "vitest";
import {
  AgentContractsClient,
  isTerminal,
  waitForAgent,
  GROUP,
  VERSION,
  type KubeRequest,
  type KubeResponse,
  type KubeTransport,
} from "./client.js";
import { enforce } from "./enforce.js";
import type { Agent, AgentDefinition, Station } from "./types.generated.js";

// A real in-memory transport: returns queued responses and records the requests
// it saw. No mocking library — a genuine fake implementation.
class FakeTransport implements KubeTransport {
  readonly seen: KubeRequest[] = [];
  constructor(private readonly responses: KubeResponse[]) {}
  async request(req: KubeRequest): Promise<KubeResponse> {
    this.seen.push(req);
    return enforce(this.responses.shift(), "FakeTransport: no response queued");
  }
}

const ok = (body: unknown): KubeResponse => ({ status: 200, body });

describe("isTerminal", () => {
  it("returns true when phase is Succeeded", () => {
    expect(isTerminal({ status: { phase: "Succeeded" } })).toBe(true);
  });
  it("returns true when phase is Failed", () => {
    expect(isTerminal({ status: { phase: "Failed" } })).toBe(true);
  });
  it("returns false when phase is Running", () => {
    expect(isTerminal({ status: { phase: "Running" } })).toBe(false);
  });
  it("returns false when status is absent", () => {
    expect(isTerminal({})).toBe(false);
  });
});

describe("createAgent", () => {
  it("POSTs to the namespaced agents path with apiVersion + kind injected", async () => {
    const created: Agent = { metadata: { name: "run-abc" }, spec: { stationRef: "impl" } };
    const t = new FakeTransport([ok(created)]);
    const client = new AgentContractsClient(t);
    const result = await client.createAgent({ spec: { stationRef: "impl" } });
    expect(result).toEqual(created);
    expect(t.seen[0]).toMatchObject({
      method: "POST",
      path: `/apis/${GROUP}/${VERSION}/namespaces/ai-agents/agents`,
      body: { apiVersion: `${GROUP}/${VERSION}`, kind: "Agent", spec: { stationRef: "impl" } },
    });
  });
});

describe("getAgent", () => {
  it("GETs the named agent in the configured namespace", async () => {
    const agent: Agent = { metadata: { name: "run-1" } };
    const t = new FakeTransport([ok(agent)]);
    const client = new AgentContractsClient(t, "team-ns");
    const result = await client.getAgent("run-1");
    expect(result).toEqual(agent);
    expect(t.seen[0].path).toBe(`/apis/${GROUP}/${VERSION}/namespaces/team-ns/agents/run-1`);
  });

  it("throws on a non-2xx response", async () => {
    const t = new FakeTransport([{ status: 404, body: { message: "not found" } }]);
    const client = new AgentContractsClient(t);
    await expect(client.getAgent("missing")).rejects.toThrow(/kube request failed \(404\)/);
  });
});

describe("findAgents", () => {
  it("lists agents with the label selector and returns items", async () => {
    const items: Agent[] = [{ metadata: { name: "a" } }, { metadata: { name: "b" } }];
    const t = new FakeTransport([ok({ items })]);
    const client = new AgentContractsClient(t);
    const result = await client.findAgents("lore/task-id=123");
    expect(result).toEqual(items);
    expect(t.seen[0].query).toEqual({ labelSelector: "lore/task-id=123" });
  });

  it("returns [] when the list has no items", async () => {
    const t = new FakeTransport([ok({})]);
    const client = new AgentContractsClient(t);
    expect(await client.findAgents("x=y")).toEqual([]);
  });
});

describe("apply", () => {
  it("server-side applies an AgentDefinition with force + apply content-type", async () => {
    const def: AgentDefinition = { metadata: { name: "bug-fixer" }, spec: { model: "claude-sonnet-4-6" } };
    const t = new FakeTransport([ok(def)]);
    const client = new AgentContractsClient(t);
    const result = await client.applyAgentDefinition(def);
    expect(result).toEqual(def);
    expect(t.seen[0]).toMatchObject({
      method: "PATCH",
      path: `/apis/${GROUP}/${VERSION}/namespaces/ai-agents/agentdefinitions/bug-fixer`,
      query: { fieldManager: "lore-ui", force: "true" },
      contentType: "application/apply-patch+yaml",
    });
  });

  it("server-side applies a Station to the stations path", async () => {
    const station: Station = {
      metadata: { name: "node-fixer" },
      spec: { agentDefRef: "bug-fixer", template: {} },
    };
    const t = new FakeTransport([ok(station)]);
    const client = new AgentContractsClient(t);
    await client.applyStation(station);
    expect(t.seen[0].path).toBe(`/apis/${GROUP}/${VERSION}/namespaces/ai-agents/stations/node-fixer`);
  });

  it("throws when the resource has no metadata.name", async () => {
    const t = new FakeTransport([]);
    const client = new AgentContractsClient(t);
    await expect(client.applyAgentDefinition({ spec: {} })).rejects.toThrow(
      "apply agentdefinitions: metadata.name is required",
    );
  });
});

describe("waitForAgent", () => {
  const terminal: Agent = { metadata: { name: "run" }, status: { phase: "Succeeded" } };
  const running: Agent = { metadata: { name: "run" }, status: { phase: "Running" } };

  it("returns immediately when the agent is already terminal (defaults)", async () => {
    const t = new FakeTransport([ok(terminal)]);
    const client = new AgentContractsClient(t);
    expect(await waitForAgent(client, "run")).toEqual(terminal);
  });

  it("polls until terminal using the default sleep", async () => {
    const t = new FakeTransport([ok(running), ok(terminal)]);
    const client = new AgentContractsClient(t);
    const result = await waitForAgent(client, "run", { intervalMs: 0 });
    expect(result).toEqual(terminal);
    expect(t.seen).toHaveLength(2);
  });

  it("throws when attempts run out", async () => {
    const t = new FakeTransport([ok(running), ok(running)]);
    const client = new AgentContractsClient(t);
    let slept = 0;
    await expect(
      waitForAgent(client, "run", { attempts: 2, sleep: async () => { slept++; } }),
    ).rejects.toThrow(/did not reach a terminal phase within 2 attempts/);
    expect(slept).toBe(2);
  });
});
