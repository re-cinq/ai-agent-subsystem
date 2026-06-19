module agentcore.crds.station;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.station_spec : StationSpec;
import agentcore.schema;

@Plural("stations")
@ShortNames(["stn"])
@PrinterColumn("Recipe", "string", ".spec.agentDefRef")
@PrinterColumn("Deadline", "integer", ".spec.deadlineMinutes")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct Station
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "Station";
	ObjectMeta metadata;
	StationSpec spec;
}
