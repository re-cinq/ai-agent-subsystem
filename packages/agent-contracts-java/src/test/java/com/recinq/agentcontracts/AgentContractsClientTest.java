package com.recinq.agentcontracts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.recinq.agentcontracts.types.Agent;
import com.recinq.agentcontracts.types.AgentSpec;
import com.recinq.agentcontracts.types.AgentStatus;
import com.recinq.agentcontracts.types.ModelCatalog;
import com.recinq.agentcontracts.types.ModelCatalogStatus;
import com.recinq.agentcontracts.types.ModelInfo;
import com.recinq.agentcontracts.types.Phase;
import com.recinq.agentcontracts.types.Station;
import com.recinq.agentcontracts.types.StationSpec;
import com.recinq.agentcontracts.types.VendorModels;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

@EnableKubernetesMockClient(crud = true)
class AgentContractsClientTest {
    KubernetesClient kube;

    private AgentContractsClient agents() {
        return new AgentContractsClient(kube, "");
    }

    private static Agent agentNamed(String name, Phase phase, Map<String, String> labels) {
        Agent agent = new Agent();
        agent.setMetadata(new ObjectMetaBuilder().withName(name).withLabels(labels).build());
        AgentSpec spec = new AgentSpec();
        spec.setStationRef("story-writer");
        agent.setSpec(spec);
        AgentStatus status = new AgentStatus();
        status.setPhase(phase);
        agent.setStatus(status);
        return agent;
    }

    @Test
    void createAgentPutsTheRunInTheClientNamespace() {
        agents().createAgent(agentNamed("run-1", Phase.PENDING, Map.of()));

        Agent created = agents().getAgent("run-1");
        assertEquals(AgentContractsClient.DEFAULT_NAMESPACE, created.getMetadata().getNamespace());
        assertEquals("story-writer", created.getSpec().getStationRef());
    }

    @Test
    void getAgentReturnsNullForAnUnknownRun() {
        assertNull(agents().getAgent("missing"));
    }

    @Test
    void findAgentsReturnsOnlyTheRunsMatchingTheSelector() {
        AgentContractsClient client = new AgentContractsClient(kube, null);
        client.createAgent(agentNamed("web-1", Phase.RUNNING, Map.of("team", "web")));
        client.createAgent(agentNamed("data-1", Phase.RUNNING, Map.of("team", "data")));

        List<Agent> found = client.findAgents("team=web");
        assertEquals(1, found.size());
        assertEquals("web-1", found.get(0).getMetadata().getName());
    }

    @Test
    void getModelCatalogReadsTheDefaultCatalog() {
        ModelInfo model = new ModelInfo();
        model.setId("claude-opus-5-5");
        VendorModels vendor = new VendorModels();
        vendor.setVendor("claude");
        vendor.setModels(List.of(model));
        ModelCatalogStatus status = new ModelCatalogStatus();
        status.setVendors(List.of(vendor));
        ModelCatalog catalog = new ModelCatalog();
        catalog.setMetadata(new ObjectMetaBuilder().withName("default")
            .withNamespace(AgentContractsClient.DEFAULT_NAMESPACE).build());
        catalog.setStatus(status);
        kube.resource(catalog).create();

        ModelCatalog read = agents().getModelCatalog();
        assertEquals("claude-opus-5-5", read.getStatus().getVendors().get(0).getModels().get(0).getId());
    }

    @Test
    void applyStationWithoutANameFails() {
        Station station = new Station();
        station.setMetadata(new ObjectMetaBuilder().build());

        IllegalArgumentException error = assertThrows(IllegalArgumentException.class,
            () -> agents().applyStation(station));
        assertEquals("apply Station: metadata.name is required", error.getMessage());
    }

    @Test
    void applyStationWithAnEmptyNameFails() {
        Station station = new Station();
        station.setMetadata(new ObjectMetaBuilder().withName("").build());

        assertThrows(IllegalArgumentException.class, () -> agents().applyStation(station));
    }

    @Test
    void waitForAgentReturnsTheRunOnceSucceeded() {
        agents().createAgent(agentNamed("run-1", Phase.SUCCEEDED, Map.of()));

        Agent finished = agents().waitForAgent("run-1", Duration.ofSeconds(5));
        assertEquals(Phase.SUCCEEDED, finished.getStatus().getPhase());
    }

    @Test
    void waitForAgentFailsWhenTheTimeoutPassesWhileRunning() {
        agents().createAgent(agentNamed("run-1", Phase.RUNNING, Map.of()));

        IllegalStateException error = assertThrows(IllegalStateException.class,
            () -> agents().waitForAgent("run-1", Duration.ofMillis(50)));
        assertEquals("agent run-1 did not reach a terminal phase within PT0.05S", error.getMessage());
    }

    @Test
    void isTerminalIsTrueOnlyForSucceededAndFailed() {
        assertFalse(AgentContractsClient.isTerminal(agentNamed("run", Phase.PENDING, Map.of())));
        assertFalse(AgentContractsClient.isTerminal(agentNamed("run", Phase.RUNNING, Map.of())));
        assertTrue(AgentContractsClient.isTerminal(agentNamed("run", Phase.SUCCEEDED, Map.of())));
        assertTrue(AgentContractsClient.isTerminal(agentNamed("run", Phase.FAILED, Map.of())));
    }

    @Test
    void isTerminalIsFalseWithoutAStatusOrAnAgent() {
        assertFalse(AgentContractsClient.isTerminal(new Agent()));
        assertFalse(AgentContractsClient.isTerminal(null));
    }
}
