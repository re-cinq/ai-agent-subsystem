# agent-contracts (Java)

Java types and a small fabric8 client for the [ai-agent-subsystem](https://github.com/re-cinq/ai-agent-subsystem)
Custom Resources: **Agent**, **Station**, **AgentDefinition**, **ModelCatalog** and **AgentSpawner** (API group
`agents.re-cinq.com/v1beta1`).

The types are generated from the D structs that define the CRDs, the same source the CRD YAML and
the TypeScript and Go contracts come from, so they cannot drift. CI fails if the committed files
stop matching the model, and a test decodes every manifest in `examples/` with unknown fields
rejected.

## Install

The jar is published to GitHub Packages on every release. Add the repository and the dependency
(GitHub Packages needs a token with `read:packages` in your `~/.m2/settings.xml`, even for public packages):

```xml
<repositories>
  <repository>
    <id>github</id>
    <url>https://maven.pkg.github.com/re-cinq/ai-agent-subsystem</url>
  </repository>
</repositories>

<dependency>
  <groupId>com.re-cinq</groupId>
  <artifactId>agent-contracts</artifactId>
  <version>0.15.0</version>
</dependency>
```

Versions follow the subsystem's releases: `0.15.0` is cut from the same commit as `v0.15.0`.
Requires Java 17+ and brings `io.fabric8:kubernetes-client` 7.x (the major Spring Cloud Kubernetes uses).

## Types

Every top-level kind extends fabric8's `CustomResource<Spec, Status>` (`Void` status for
AgentDefinition and Station), is `Namespaced`, carries `@Group`, `@Version`, `@Plural` and
`@ShortNames`, and has a `<Kind>List`, so it works with any fabric8 client without registration:

```java
Agent run = kube.resources(Agent.class).inNamespace("ai-agents").withName("run-1").get();
```

Nested types (`AgentSpec`, `StationSpec`, `McpServer`, ...) are plain Jackson beans with getters,
setters, `equals`, `hashCode` and `toString`. Numbers and booleans are boxed: leave a field `null` and
the API server applies the CRD's default (for example `StationSpec.deadlineMinutes`). Free-form fields
such as `StationSpec.template` are `JsonNode`. An enum decodes an unknown wire value to its first
member, the same lenient rule the controller applies, so a newer server never breaks an older client.
`ApiGroup.GROUP`, `VERSION` and `API_VERSION` hold the group constants.

## Client

`AgentContractsClient` wraps a `KubernetesClient` and works in one namespace (`ai-agents` by default).
In a Spring Boot app with Spring Cloud Kubernetes, expose it as a bean:

```java
@Bean
AgentContractsClient agentContracts(KubernetesClient kube) {
    return new AgentContractsClient(kube, "ai-agents");
}
```

```java
Agent run = new Agent();
run.setMetadata(new ObjectMetaBuilder().withGenerateName("story-writer-run-").build());

AgentSpec spec = new AgentSpec();
spec.setStationRef("story-writer");
spec.setParameters(Map.of("title", "The Last Lighthouse"));
run.setSpec(spec);

Agent started = agentContracts.createAgent(run);
Agent finished = agentContracts.waitForAgent(started.getMetadata().getName(), Duration.ofMinutes(30));
```

| Method | Does |
| --- | --- |
| `createAgent` | Start one run. |
| `getAgent`, `findAgents` | Read one run, or list runs by label selector. |
| `waitForAgent` | Watch until the run is `Succeeded` or `Failed`; `IllegalStateException` after the timeout. |
| `getModelCatalog` | The models the subsystem can run with its configured keys. |
| `applyAgentDefinition`, `applyStation` | Server-side apply a recipe or runtime (field manager `agent-contracts`, forced). |
| `isTerminal` | Whether a run has finished. |

## Development

`make regen` from the repository root rewrites `src/main/java/com/recinq/agentcontracts/types/`; do
not edit those files by hand. `make contracts-java` compiles, runs the JUnit tests against fabric8's
mock server and enforces 100% coverage on the hand-written client.
