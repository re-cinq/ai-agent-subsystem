package com.recinq.agentcontracts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.recinq.agentcontracts.types.AgentDefinition;
import com.recinq.agentcontracts.types.AgentDefinitionSpec;
import com.recinq.agentcontracts.types.Station;
import com.recinq.agentcontracts.types.StationSpec;
import io.fabric8.kubernetes.api.model.ManagedFieldsEntry;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import io.fabric8.kubernetes.client.KubernetesClient;
import io.fabric8.kubernetes.client.server.mock.EnableKubernetesMockClient;
import io.fabric8.kubernetes.client.server.mock.KubernetesMockServer;
import io.fabric8.mockwebserver.http.RecordedRequest;
import java.util.List;
import org.junit.jupiter.api.Test;

/** The CRUD mock has no server-side apply, so these tests check the request the client sends. */
@EnableKubernetesMockClient
class ServerSideApplyTest {
    KubernetesMockServer server;
    KubernetesClient kube;

    @Test
    void applyStationSendsAForcedApplyPatchInTheClientNamespace() throws Exception {
        Station station = new Station();
        station.setMetadata(new ObjectMetaBuilder().withName("story-writer")
            .withManagedFields(List.of(new ManagedFieldsEntry())).build());
        StationSpec spec = new StationSpec();
        spec.setAgentDefRef("story-writer");
        station.setSpec(spec);
        server.expect().patch()
            .withPath("/apis/agents.re-cinq.com/v1beta1/namespaces/team-a/stations/story-writer?fieldManager=agent-contracts&force=true")
            .andReturn(200, station).once();

        Station applied = new AgentContractsClient(kube, "team-a").applyStation(station);

        RecordedRequest request = server.getLastRequest();
        assertEquals("application/apply-patch+yaml", request.getHeader("Content-Type"));
        assertTrue(request.getBody().readUtf8().contains("\"agentDefRef\":\"story-writer\""));
        assertNull(station.getMetadata().getManagedFields());
        assertEquals("team-a", station.getMetadata().getNamespace());
        assertEquals("story-writer", applied.getSpec().getAgentDefRef());
    }

    @Test
    void applyAgentDefinitionSendsAnApplyPatch() {
        AgentDefinition definition = new AgentDefinition();
        definition.setMetadata(new ObjectMetaBuilder().withName("story-writer").build());
        AgentDefinitionSpec spec = new AgentDefinitionSpec();
        spec.setModel("claude-opus-5-5");
        definition.setSpec(spec);
        server.expect().patch()
            .withPath("/apis/agents.re-cinq.com/v1beta1/namespaces/ai-agents/agentdefinitions/story-writer?fieldManager=agent-contracts&force=true")
            .andReturn(200, definition).once();

        AgentDefinition applied = new AgentContractsClient(kube, "").applyAgentDefinition(definition);

        assertEquals("claude-opus-5-5", applied.getSpec().getModel());
    }
}
