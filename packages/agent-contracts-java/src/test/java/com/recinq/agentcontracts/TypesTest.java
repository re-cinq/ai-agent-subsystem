package com.recinq.agentcontracts;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import com.recinq.agentcontracts.types.Agent;
import com.recinq.agentcontracts.types.AgentDefinition;
import com.recinq.agentcontracts.types.AgentSpawner;
import com.recinq.agentcontracts.types.ApiGroup;
import com.recinq.agentcontracts.types.ModelCatalog;
import com.recinq.agentcontracts.types.PermissionMode;
import com.recinq.agentcontracts.types.SecretRef;
import com.recinq.agentcontracts.types.Station;
import com.recinq.agentcontracts.types.StationSpec;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;

class TypesTest {
    private static final Map<String, Class<?>> KINDS = Map.of(
        "AgentDefinition", AgentDefinition.class,
        "Station", Station.class,
        "Agent", Agent.class,
        "ModelCatalog", ModelCatalog.class,
        "AgentSpawner", AgentSpawner.class);

    private static final ObjectMapper STRICT_YAML = new ObjectMapper(new YAMLFactory())
        .enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);

    /** Every manifest under examples/ decodes with unknown fields rejected, so a field the CRDs accept but the Java types miss fails here. */
    @Test
    void everyExampleManifestDecodesStrictly() throws IOException {
        int decoded = 0;
        try (Stream<Path> files = Files.list(Path.of("../../examples"))) {
            for (Path file : files.filter(path -> path.toString().endsWith(".yaml")).toList()) {
                for (String document : Files.readString(file).split("\n---")) {
                    decoded += decodeStrictly(file, document);
                }
            }
        }
        assertTrue(decoded > 0, "decoded no resources");
    }

    private static int decodeStrictly(Path file, String document) throws IOException {
        JsonNode tree = STRICT_YAML.readTree(document);
        if (tree == null || !tree.hasNonNull("kind")) {
            return 0;
        }
        String kind = tree.get("kind").asText();
        assertTrue(KINDS.containsKey(kind), file + ": kind " + kind + " is not a generated type");
        Object resource = STRICT_YAML.treeToValue(tree, KINDS.get(kind));
        assertEquals(ApiGroup.API_VERSION, ((io.fabric8.kubernetes.api.model.HasMetadata) resource).getApiVersion(),
            file + ": " + kind);
        return 1;
    }

    @Test
    void unknownEnumValueFallsBackToTheFirstMember() throws IOException {
        PermissionMode parsed = new ObjectMapper().readValue("\"bogus\"", PermissionMode.class);
        assertEquals(PermissionMode.AUTO, parsed);
        assertEquals(PermissionMode.BYPASS, PermissionMode.fromWire("bypass"));
    }

    @Test
    void unsetFieldsAreOmittedOnTheWire() throws IOException {
        StationSpec spec = new StationSpec();
        spec.setAgentDefRef("story-writer");

        assertEquals("{\"agentDefRef\":\"story-writer\"}", new ObjectMapper().writeValueAsString(spec));
    }

    @Test
    void equalSpecsCompareEqualAndDescribeThemselves() {
        SecretRef first = new SecretRef();
        first.setName("GITHUB_TOKEN");
        first.setRef("github-token");
        SecretRef second = new SecretRef();
        second.setName("GITHUB_TOKEN");
        second.setRef("github-token");
        SecretRef other = new SecretRef();
        other.setName("OTHER");

        assertEquals(first, second);
        assertEquals(first.hashCode(), second.hashCode());
        assertNotEquals(first, other);
        assertFalse(first.equals("GITHUB_TOKEN"));
        assertEquals("SecretRef{name=GITHUB_TOKEN, ref=github-token}", first.toString());
        assertEquals(List.of("GITHUB_TOKEN"), List.of(first.getName()));
    }

    @Test
    void kindsCarryTheirGroupVersionAndPlural() {
        Agent agent = new Agent();
        assertEquals("agents.re-cinq.com/v1beta1", agent.getApiVersion());
        assertEquals("Agent", agent.getKind());
        assertEquals("agents", agent.getPlural());
        assertEquals("agents.re-cinq.com", ApiGroup.GROUP);
        assertEquals("v1beta1", ApiGroup.VERSION);
    }
}
