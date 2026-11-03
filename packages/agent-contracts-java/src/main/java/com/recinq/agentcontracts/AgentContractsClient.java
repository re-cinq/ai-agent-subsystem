package com.recinq.agentcontracts;

import com.recinq.agentcontracts.types.Agent;
import com.recinq.agentcontracts.types.AgentDefinition;
import com.recinq.agentcontracts.types.ModelCatalog;
import com.recinq.agentcontracts.types.Phase;
import com.recinq.agentcontracts.types.Station;
import io.fabric8.kubernetes.api.model.HasMetadata;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.KubernetesClientTimeoutException;
import io.fabric8.kubernetes.api.model.KubernetesResourceList;
import io.fabric8.kubernetes.client.dsl.NonNamespaceOperation;
import io.fabric8.kubernetes.client.dsl.Resource;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Creates and reads the subsystem's resources in one namespace through a fabric8
 * {@link KubernetesClient}, such as the one Spring Cloud Kubernetes injects.
 */
public class AgentContractsClient {
    /** The namespace the subsystem installs into and runs Agents in. */
    public static final String DEFAULT_NAMESPACE = "ai-agents";

    private static final String FIELD_MANAGER = "agent-contracts";
    private static final String MODEL_CATALOG_NAME = "default";

    private final KubernetesClient kube;
    private final String namespace;

    /** A client for {@code namespace}, or {@link #DEFAULT_NAMESPACE} when it is null or blank. */
    public AgentContractsClient(KubernetesClient kube, String namespace) {
        this.kube = kube;
        this.namespace = namespace == null || namespace.isBlank() ? DEFAULT_NAMESPACE : namespace;
    }

    /** Starts one run. The Agent's namespace is set to the client's namespace. */
    public Agent createAgent(Agent agent) {
        agent.getMetadata().setNamespace(namespace);
        return agents().resource(agent).create();
    }

    /** Reads one Agent by name, or null when it does not exist. */
    public Agent getAgent(String name) {
        return agents().withName(name).get();
    }

    /** Lists the Agents matching a Kubernetes label selector such as {@code team=web}. */
    public List<Agent> findAgents(String labelSelector) {
        return agents().withLabelSelector(labelSelector).list().getItems();
    }

    /** Reads the models the subsystem can run (the controller's {@code default} ModelCatalog). */
    public ModelCatalog getModelCatalog() {
        return kube.resources(ModelCatalog.class).inNamespace(namespace).withName(MODEL_CATALOG_NAME).get();
    }

    /** Server-side applies an AgentDefinition, taking over fields other managers set. */
    public AgentDefinition applyAgentDefinition(AgentDefinition definition) {
        return apply(definition);
    }

    /** Server-side applies a Station, taking over fields other managers set. */
    public Station applyStation(Station station) {
        return apply(station);
    }

    private <T extends HasMetadata> T apply(T resource) {
        String name = resource.getMetadata().getName();
        if (name == null || name.isEmpty()) {
            throw new IllegalArgumentException("apply " + resource.getKind() + ": metadata.name is required");
        }
        resource.getMetadata().setNamespace(namespace);
        resource.getMetadata().setManagedFields(null);
        return kube.resource(resource).fieldManager(FIELD_MANAGER).forceConflicts().serverSideApply();
    }

    /** Whether a run has finished (Succeeded or Failed). */
    public static boolean isTerminal(Agent agent) {
        if (agent == null || agent.getStatus() == null) {
            return false;
        }
        Phase phase = agent.getStatus().getPhase();
        return phase == Phase.SUCCEEDED || phase == Phase.FAILED;
    }

    /** Waits until the run reaches a terminal phase, or throws once {@code timeout} passes. */
    public Agent waitForAgent(String name, Duration timeout) {
        Resource<Agent> run = agents().withName(name);
        try {
            return run.waitUntilCondition(AgentContractsClient::isTerminal, timeout.toMillis(), TimeUnit.MILLISECONDS);
        } catch (KubernetesClientTimeoutException timedOut) {
            throw new IllegalStateException("agent " + name + " did not reach a terminal phase within " + timeout, timedOut);
        }
    }

    private NonNamespaceOperation<Agent, KubernetesResourceList<Agent>, Resource<Agent>> agents() {
        return kube.resources(Agent.class).inNamespace(namespace);
    }
}
