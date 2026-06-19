module agentcore.crds;

// Typed model of the three Custom Resources (agents.re-cinq.com/v1alpha1), one
// type per module. @Json carries the wire name where it differs from the D
// identifier (snake_case fields and the `ref`/`template` keywords);
// @Description, @Required, @Minimum and @PreserveUnknownFields carry the rest
// of the schema metadata D types cannot express on their own.

public import agentcore.crds.enums;
public import agentcore.crds.object_meta;
public import agentcore.crds.env_var;
public import agentcore.crds.secret_ref;
public import agentcore.crds.mcp_server;
public import agentcore.crds.repo_ref;
public import agentcore.crds.agent_resources;
public import agentcore.crds.output_selector;
public import agentcore.crds.output_sink;
public import agentcore.crds.output_spec;
public import agentcore.crds.agent_definition_spec;
public import agentcore.crds.agent_definition;
public import agentcore.crds.station_spec;
public import agentcore.crds.station;
public import agentcore.crds.agent_spec;
public import agentcore.crds.agent_status;
public import agentcore.crds.agent;
