package com.recinq.agentcontracts;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.recinq.agentcontracts.types.Agent;
import com.recinq.agentcontracts.types.AgentSpec;
import com.recinq.agentcontracts.types.AgentStatus;
import com.recinq.agentcontracts.types.Phase;
import io.fabric8.kubernetes.api.model.ObjectMetaBuilder;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.http.converter.json.Jackson2ObjectMapperBuilder;

/** Spring's default ObjectMapper configuration round-trips the generated types unchanged. */
class SpringCompatibilityTest {
    @Test
    void springObjectMapperRoundTripsAnAgent() throws Exception {
        ObjectMapper mapper = new Jackson2ObjectMapperBuilder().build();
        Agent agent = new Agent();
        agent.setMetadata(new ObjectMetaBuilder().withName("run-1").withNamespace("ai-agents").build());
        AgentSpec spec = new AgentSpec();
        spec.setStationRef("story-writer");
        spec.setParameters(Map.of("title", "The Last Lighthouse"));
        agent.setSpec(spec);
        AgentStatus status = new AgentStatus();
        status.setPhase(Phase.RUNNING);
        agent.setStatus(status);

        Agent decoded = mapper.readValue(mapper.writeValueAsString(agent), Agent.class);

        assertEquals(agent.getSpec(), decoded.getSpec());
        assertEquals(agent.getStatus(), decoded.getStatus());
        assertEquals("run-1", decoded.getMetadata().getName());
    }
}
