module agentcore.crds.station;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.station_spec : StationSpec;
import agentcore.crds.schema;

@Plural("stations")
@ShortNames(["stn"])
@PrinterColumn("Recipe", "string", ".spec.agentDefRef")
@PrinterColumn("Deadline", "integer", ".spec.deadlineMinutes")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct Station
{
	@optional string apiVersion = "agents.re-cinq.com/v1alpha1";
	@optional string kind = "Station";
	@optional ObjectMeta metadata;
	@optional StationSpec spec;
}
