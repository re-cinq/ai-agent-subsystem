/// Every CRD type the code generators emit, listed once. crdgen writes a CRD per kind
/// in `CrdKinds`; tsgen and the Go emitter write a type per enum and struct. Adding a
/// CRD or a nested type means adding it here, and `make drift` catches the rest.
module agentcore.crds.registry;

import std.meta : AliasSeq;

import agentcore.crds.enums : PermissionMode, McpTransport, OutputFormat, SelectEvent,
	SelectRole, SinkType, ConcurrencyPolicy, SpawnerConcurrencyPolicy, Execution, BatchTimeoutAction;
import agentcore.core.types : Phase;
import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.env_var : EnvVar;
import agentcore.crds.secret_ref : SecretRef;
import agentcore.crds.mcp_server : McpHeader, McpServer;
import agentcore.crds.repo_ref : RepoRef;
import agentcore.crds.conversation_ref : ConversationRef;
import agentcore.crds.agent_resources : AgentResources;
import agentcore.crds.output_selector : OutputSelector;
import agentcore.crds.output_sink : OutputSink;
import agentcore.crds.output_watch : OutputWatch;
import agentcore.crds.watch_upload : WatchUpload;
import agentcore.crds.input_file : InputFile;
import agentcore.crds.output_spec : OutputSpec;
import agentcore.crds.agent_definition_spec : AgentDefinitionSpec, BatchSpec, RealtimeSpec;
import agentcore.crds.agent_definition : AgentDefinition;
import agentcore.crds.station_spec : StationSpec;
import agentcore.crds.station : Station;
import agentcore.crds.agent_spec : AgentSpec;
import agentcore.crds.agent_status : AgentStatus;
import agentcore.crds.agent : Agent;
import agentcore.crds.model_catalog : ModelCatalog, ModelCatalogStatus, ModelInfo, VendorModels;
import agentcore.crds.agent_spawner : AgentSpawner, AgentSpawnerSpec, AgentSpawnerStatus;

/// The top-level resources, one CustomResourceDefinition each.
alias CrdKinds = AliasSeq!(AgentDefinition, Station, Agent, ModelCatalog, AgentSpawner);

/// The enums, in declaration order.
alias CrdEnums = AliasSeq!(PermissionMode, McpTransport, OutputFormat,
	SelectEvent, SelectRole, SinkType, ConcurrencyPolicy, SpawnerConcurrencyPolicy, Execution, BatchTimeoutAction,
	Phase);

/// Every struct, dependency-first so the generated files read top-down.
alias CrdStructs = AliasSeq!(ObjectMeta, EnvVar, SecretRef, McpHeader, McpServer, RepoRef,
	ConversationRef, AgentResources, OutputSelector, OutputSink, WatchUpload, OutputWatch, OutputSpec,
	BatchSpec, RealtimeSpec, AgentDefinitionSpec, AgentDefinition, StationSpec, Station, InputFile, AgentSpec,
	AgentStatus, Agent, ModelInfo, VendorModels, ModelCatalogStatus, ModelCatalog, AgentSpawnerSpec,
	AgentSpawnerStatus, AgentSpawner);
