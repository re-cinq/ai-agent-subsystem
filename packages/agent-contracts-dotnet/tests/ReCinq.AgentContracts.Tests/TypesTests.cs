using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using k8s;
using YamlDotNet.Core;
using YamlDotNet.RepresentationModel;

namespace ReCinq.AgentContracts.Tests;

public sealed partial class TypesTests
{
    private static readonly Dictionary<string, Type> Kinds = new()
    {
        ["AgentDefinition"] = typeof(AgentDefinition),
        ["Station"] = typeof(Station),
        ["Agent"] = typeof(Agent),
        ["ModelCatalog"] = typeof(ModelCatalog),
        ["AgentSpawner"] = typeof(AgentSpawner),
    };

    private static readonly JsonSerializerOptions Strict = new() { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };

    /// <summary>Every manifest under examples/ decodes with unknown fields rejected, so a field the CRDs accept but the C# types miss fails here.</summary>
    [Fact]
    public void EveryExampleManifestDecodesStrictly()
    {
        var examples = Path.Combine(AppContext.BaseDirectory, "../../../../../../../examples");
        var decoded = 0;
        foreach (var file in Directory.GetFiles(examples, "*.yaml"))
        {
            var stream = new YamlStream();
            stream.Load(new StringReader(File.ReadAllText(file)));
            foreach (var document in stream.Documents)
            {
                var json = ToJson(document.RootNode);
                if (json?["kind"] is not JsonValue kind)
                {
                    continue;
                }
                Assert.True(Kinds.ContainsKey(kind.GetValue<string>()), $"{file}: kind {kind} is not a generated type");
                var resource = (IKubernetesObject)json.Deserialize(Kinds[kind.GetValue<string>()], Strict)!;
                Assert.Equal(ApiGroup.ApiVersion, resource.ApiVersion);
                decoded++;
            }
        }
        Assert.True(decoded > 0, "decoded no resources");
    }

    [Fact]
    public void AnUnknownEnumValueFallsBackToTheFirstMember()
    {
        var statuses = KubernetesJson.Deserialize<List<AgentStatus>>("""[{"phase":"bogus"},{"phase":"Failed"}]""");

        Assert.Equal([Phase.Pending, Phase.Failed], statuses.Select(status => status.Phase));
    }

    [Fact]
    public void EnumsAndUnsetFieldsSerializeAsTheWireExpects()
    {
        var selector = new OutputSelector { Event = SelectEvent.ToolCall };

        Assert.Equal("""{"event":"tool_call"}""", KubernetesJson.Serialize(selector));
    }

    [Fact]
    public void AKindCarriesItsGroupVersionPluralAndShortNames()
    {
        var agent = new Agent();

        Assert.Equal(("agents.re-cinq.com/v1beta1", "Agent", "agents", "agt"),
            (agent.ApiVersion, agent.Kind, Agent.Plural, string.Join(",", Agent.ShortNames)));
    }

    [Fact]
    public void EveryWireValueRoundTrips()
    {
        Assert.All(Enum.GetValues<OutputFormat>(), format => Assert.Equal(format, OutputFormatWire.FromWire(format.ToWire())));
        Assert.Throws<ArgumentOutOfRangeException>(() => ((OutputFormat)99).ToWire());
    }

    private static JsonNode? ToJson(YamlNode node) => node switch
    {
        YamlMappingNode mapping => new JsonObject(mapping.Children.Select(child =>
            KeyValuePair.Create(((YamlScalarNode)child.Key).Value!, ToJson(child.Value)))),
        YamlSequenceNode sequence => new JsonArray(sequence.Children.Select(ToJson).ToArray()),
        YamlScalarNode { Style: ScalarStyle.Plain } scalar when scalar.Value is "null" or "~" or "" => null,
        YamlScalarNode { Style: ScalarStyle.Plain } scalar when scalar.Value is "true" or "false" => JsonValue.Create(scalar.Value == "true"),
        YamlScalarNode { Style: ScalarStyle.Plain } scalar when Integer().IsMatch(scalar.Value!) => JsonValue.Create(long.Parse(scalar.Value!)),
        YamlScalarNode scalar => JsonValue.Create(scalar.Value),
        _ => throw new NotSupportedException(node.GetType().Name),
    };

    [GeneratedRegex("^-?[0-9]+$")]
    private static partial Regex Integer();
}
