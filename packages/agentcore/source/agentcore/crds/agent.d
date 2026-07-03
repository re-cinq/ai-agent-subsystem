module agentcore.crds.agent;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.agent_spec : AgentSpec;
import agentcore.crds.agent_status : AgentStatus;
import agentcore.crds.schema;

@Plural("agents")
@ShortNames(["agt"])
@PrinterColumn("Phase", "string", ".status.phase")
@PrinterColumn("Station", "string", ".spec.stationRef")
@PrinterColumn("Job", "string", ".status.jobName")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct Agent
{
	@optional string apiVersion = "agents.re-cinq.com/v1alpha1";
	@optional string kind = "Agent";
	@optional ObjectMeta metadata;
	@optional AgentSpec spec;
	@optional AgentStatus status;
}
