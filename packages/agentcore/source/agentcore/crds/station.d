module agentcore.crds.station;

import agentcore.crds.object_meta : ObjectMeta;
import agentcore.crds.station_spec : StationSpec;

struct Station
{
	string apiVersion = "agents.re-cinq.com/v1alpha1";
	string kind = "Station";
	ObjectMeta metadata;
	StationSpec spec;
}
