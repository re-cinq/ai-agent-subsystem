// Thin, typed client over the Kubernetes API for the agents.re-cinq.com CRDs.
// IO is injected as a KubeTransport so the client logic is deterministically
// testable with an in-memory fake (no cluster, no mocks). A concrete transport
// (fetch / @kubernetes/client-node) is supplied by the consumer (the Floor / UI).

import type { Agent, AgentDefinition, Station, Phase } from "./types.generated.js";

export const GROUP = "agents.re-cinq.com";
export const VERSION = "v1alpha1";
export const DEFAULT_NAMESPACE = "ai-agents";

const FIELD_MANAGER = "lore-ui";
const TERMINAL_PHASES: readonly Phase[] = ["Succeeded", "Failed"];

export interface KubeRequest {
  method: "GET" | "POST" | "PATCH";
  path: string;
  query?: Record<string, string>;
  body?: unknown;
  contentType?: string;
}

export interface KubeResponse {
  status: number;
  body: unknown;
}

export interface KubeTransport {
  request(req: KubeRequest): Promise<KubeResponse>;
}

/** True once an Agent run has reached a terminal phase (Succeeded / Failed). */
export function isTerminal(agent: Agent): boolean {
  const phase = agent.status?.phase;
  return phase !== undefined && TERMINAL_PHASES.includes(phase);
}

function namespacedPath(plural: string, namespace: string): string {
  return `/apis/${GROUP}/${VERSION}/namespaces/${namespace}/${plural}`;
}

function expectOk(res: KubeResponse): unknown {
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`kube request failed (${res.status}): ${JSON.stringify(res.body)}`);
  }
  return res.body;
}

/** Typed client for the Agent / Station / AgentDefinition resources. */
export class AgentContractsClient {
  constructor(
    private readonly transport: KubeTransport,
    private readonly namespace: string = DEFAULT_NAMESPACE,
  ) {}

  /** Create one Agent run. */
  async createAgent(agent: Agent): Promise<Agent> {
    const res = await this.transport.request({
      method: "POST",
      path: namespacedPath("agents", this.namespace),
      body: { apiVersion: `${GROUP}/${VERSION}`, kind: "Agent", ...agent },
    });
    return expectOk(res) as Agent;
  }

  /** Read one Agent by name. */
  async getAgent(name: string): Promise<Agent> {
    const res = await this.transport.request({
      method: "GET",
      path: `${namespacedPath("agents", this.namespace)}/${name}`,
    });
    return expectOk(res) as Agent;
  }

  /** List Agents matching a Kubernetes label selector. */
  async findAgents(labelSelector: string): Promise<Agent[]> {
    const res = await this.transport.request({
      method: "GET",
      path: namespacedPath("agents", this.namespace),
      query: { labelSelector },
    });
    const list = expectOk(res) as { items?: Agent[] };
    return list.items ?? [];
  }

  /** Server-side apply an AgentDefinition (the UI uses this to push edited YAML). */
  applyAgentDefinition(def: AgentDefinition): Promise<AgentDefinition> {
    return this.apply("agentdefinitions", def) as Promise<AgentDefinition>;
  }

  /** Server-side apply a Station. */
  applyStation(station: Station): Promise<Station> {
    return this.apply("stations", station) as Promise<Station>;
  }

  private async apply(
    plural: string,
    resource: { metadata?: { name?: string } },
  ): Promise<unknown> {
    const name = resource.metadata?.name;
    if (!name) {
      throw new Error(`apply ${plural}: metadata.name is required`);
    }
    const res = await this.transport.request({
      method: "PATCH",
      path: `${namespacedPath(plural, this.namespace)}/${name}`,
      query: { fieldManager: FIELD_MANAGER, force: "true" },
      body: resource,
      contentType: "application/apply-patch+yaml",
    });
    return expectOk(res);
  }
}

export interface WaitOptions {
  attempts?: number;
  intervalMs?: number;
  sleep?: (ms: number) => Promise<void>;
}

const realSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/** Poll `getAgent` until the run reaches a terminal phase, or attempts run out. */
export async function waitForAgent(
  client: Pick<AgentContractsClient, "getAgent">,
  name: string,
  options: WaitOptions = {},
): Promise<Agent> {
  const attempts = options.attempts ?? 600;
  const intervalMs = options.intervalMs ?? 2000;
  const sleep = options.sleep ?? realSleep;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const agent = await client.getAgent(name);
    if (isTerminal(agent)) {
      return agent;
    }
    await sleep(intervalMs);
  }
  throw new Error(`agent ${name} did not reach a terminal phase within ${attempts} attempts`);
}
