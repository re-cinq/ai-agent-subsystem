---
title: Java client
description: Launch and watch Agents from Java and Spring Boot with the fabric8-based agent-contracts library.
---

`com.re-cinq:agent-contracts` gives a Java program the types of every resource as fabric8 custom
resources and a small client that creates runs, waits for them and applies recipes. The types are
generated from the same source as the CRDs, so they always match the cluster you install from the
same release. It needs Java 17 or newer.

## Install

The jar is published to GitHub Packages on every release. GitHub Packages asks for a token even
for public packages, so add a server entry with a personal access token that has `read:packages`
to `~/.m2/settings.xml`:

```xml
<servers>
  <server>
    <id>github</id>
    <username>YOUR_GITHUB_USER</username>
    <password>YOUR_TOKEN</password>
  </server>
</servers>
```

Then add the repository and the dependency to your `pom.xml`:

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

With Gradle, add the same URL as a `maven` repository with credentials, and depend on
`com.re-cinq:agent-contracts:0.15.0`. The library brings `io.fabric8:kubernetes-client` 7.x.

## Create the client

The client wraps any fabric8 `KubernetesClient`:

```java
KubernetesClient kube = new KubernetesClientBuilder().build(); // kubeconfig or in-cluster service account
AgentContractsClient agents = new AgentContractsClient(kube, "ai-agents");
```

A `null` or blank namespace means `ai-agents`.

### In Spring Boot

Spring Cloud Kubernetes (the fabric8 flavour, `spring-cloud-starter-kubernetes-fabric8`) already
provides a `KubernetesClient` bean. Wrap it once:

```java
@Configuration
class AgentContractsConfiguration {
    @Bean
    AgentContractsClient agentContracts(KubernetesClient kube,
            @Value("${agents.namespace:ai-agents}") String namespace) {
        return new AgentContractsClient(kube, namespace);
    }
}
```

Without Spring Cloud Kubernetes, declare the `KubernetesClient` bean yourself with
`new KubernetesClientBuilder().build()` and close it on shutdown. The generated types are plain
Jackson beans, so Spring's default `ObjectMapper` reads and writes them unchanged, for example
when a controller returns an `Agent` as JSON.

## Launch a run and wait for it

```java
Agent run = new Agent();
run.setMetadata(new ObjectMetaBuilder().withGenerateName("fix-bug-").build());
AgentSpec spec = new AgentSpec();
spec.setStationRef("bug-fixer");
spec.setTargetRepo("re-cinq/ai-agent-subsystem");
spec.setParameters(Map.of("issue", "123"));
run.setSpec(spec);

Agent started = agents.createAgent(run);
Agent finished = agents.waitForAgent(started.getMetadata().getName(), Duration.ofMinutes(30));
System.out.println(finished.getStatus().getPhase() + " " + finished.getStatus().getPrUrl());
```

`waitForAgent` watches the run until the phase is `SUCCEEDED` or `FAILED`. It throws
`IllegalStateException` when the timeout passes first. It blocks the calling thread, so in a web
request handler run it on an executor or a virtual thread.

## Apply a recipe and a runtime

```java
AgentDefinition definition = new AgentDefinition();
definition.setMetadata(new ObjectMetaBuilder().withName("bug-fixer").build());
AgentDefinitionSpec recipe = new AgentDefinitionSpec();
recipe.setModel("claude-sonnet-5-5");
recipe.setPrompt("Fix the bug described in issue {issue}.");
definition.setSpec(recipe);
agents.applyAgentDefinition(definition);
```

`applyAgentDefinition` and `applyStation` are server-side apply with the field manager
`agent-contracts` and forced ownership. A resource without a name throws
`IllegalArgumentException("apply <Kind>: metadata.name is required")` before any request is sent.

## Methods

| Call | Does |
| --- | --- |
| `createAgent(agent)` | Start one run in the client's namespace. |
| `getAgent(name)` | Read one run, or `null` when it does not exist. |
| `findAgents(labelSelector)` | List runs matching a selector such as `team=web`. |
| `getModelCatalog()` | Read the models the subsystem can run. |
| `applyAgentDefinition`, `applyStation` | Server-side apply a recipe or runtime. |
| `AgentContractsClient.isTerminal(agent)` | Whether a run has finished. |
| `waitForAgent(name, timeout)` | Watch until the run finishes or the timeout passes. |

Failed API calls surface as fabric8's `KubernetesClientException`.

## Permissions

The [`agent-launcher` role](../reference/rbac-and-network.md#caller-role) covers creating, reading
and listing Agents and reading the ModelCatalog. Applying AgentDefinitions and Stations needs
`get`, `create` and `patch` on `agentdefinitions` and `stations`, which that role does not grant;
bind a separate role for the app that manages recipes.

## Types

Every kind extends fabric8's `CustomResource<Spec, Status>` and carries its group, version, plural
and short names, so you can also use fabric8 directly, for example
`kube.resources(Agent.class).inNamespace("ai-agents").inform(handler)` to react to every run.

Numbers and booleans are boxed: leave a field `null` and the API server applies the CRD's default.
Free-form fields such as `StationSpec.template` are Jackson `JsonNode`. An enum decodes a value it
does not know to its first member, the same rule the controller applies, so a newer cluster does
not break an older client.

## Test without a cluster

fabric8's mock server runs the client in a unit test:

```java
@EnableKubernetesMockClient(crud = true)
class LaunchTest {
    KubernetesClient kube;

    @Test
    void createsTheRun() {
        AgentContractsClient agents = new AgentContractsClient(kube, null);
        // createAgent, getAgent, findAgents and waitForAgent work against the in-memory API.
    }
}
```

Add `io.fabric8:kubernetes-server-mock` as a test dependency. Its CRUD mode does not implement
server-side apply, so test `applyStation` and `applyAgentDefinition` with expectations instead.
