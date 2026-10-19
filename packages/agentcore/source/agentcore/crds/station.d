module agentcore.crds.station;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.station_spec : StationSpec;
import agentcore.crds.api_group : crApiVersion;
import agentcore.crds.schema;

@Plural("stations")
@ShortNames(["stn"])
@PrinterColumn("Recipe", "string", ".spec.agentDefRef")
@PrinterColumn("Deadline", "integer", ".spec.deadlineMinutes")
@PrinterColumn("Age", "date", ".metadata.creationTimestamp")
struct Station
{
	@optional string apiVersion = crApiVersion;
	@optional string kind = "Station";
	@optional ObjectMeta metadata;
	@optional StationSpec spec;
}
