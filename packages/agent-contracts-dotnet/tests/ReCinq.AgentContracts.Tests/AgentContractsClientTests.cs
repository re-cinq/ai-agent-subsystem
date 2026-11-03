using System.Net;
using System.Text.Json.Nodes;
using k8s.Autorest;
using k8s.Models;

namespace ReCinq.AgentContracts.Tests;

public sealed class AgentContractsClientTests
{
    private const string Agents = "/apis/agents.re-cinq.com/v1beta1/namespaces/ai-agents/agents";

    private readonly FakeApiServer server = new();

    private static Agent AgentNamed(string name, Phase phase, Dictionary<string, string>? labels = null) => new()
    {
        Metadata = new V1ObjectMeta { Name = name, Labels = labels },
        Spec = new AgentSpec { StationRef = "story-writer" },
        Status = new AgentStatus { Phase = phase },
    };

    [Fact]
    public async Task CreateAgentPutsTheRunInTheClientNamespace()
    {
        var run = new Agent { Metadata = new V1ObjectMeta { GenerateName = "run-" }, Spec = new AgentSpec { StationRef = "story-writer" } };

        var created = await new AgentContractsClient(server.Client()).CreateAgentAsync(run, TestContext.Current.CancellationToken);

        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""
            {"apiVersion":"agents.re-cinq.com/v1beta1","kind":"Agent",
             "metadata":{"generateName":"run-","namespace":"ai-agents","name":"run-1"},"spec":{"stationRef":"story-writer"}}
            """), server.Objects[$"{Agents}/run-1"]), server.Objects[$"{Agents}/run-1"].ToJsonString());
        Assert.Equal("run-1", created.Metadata.Name);
    }

    [Fact]
    public async Task GetAgentFailsWithTheApi404ForAnUnknownRun()
    {
        var error = await Assert.ThrowsAsync<HttpOperationException>(() =>
            new AgentContractsClient(server.Client()).GetAgentAsync("missing", TestContext.Current.CancellationToken));

        Assert.Equal(HttpStatusCode.NotFound, error.Response.StatusCode);
    }

    [Fact]
    public async Task FindAgentsReturnsOnlyTheRunsMatchingTheSelector()
    {
        var agents = new AgentContractsClient(server.Client(), "");
        await agents.CreateAgentAsync(AgentNamed("web-1", Phase.Running, new() { ["team"] = "web" }), TestContext.Current.CancellationToken);
        await agents.CreateAgentAsync(AgentNamed("data-1", Phase.Running, new() { ["team"] = "data" }), TestContext.Current.CancellationToken);

        var found = await agents.FindAgentsAsync("team=web", TestContext.Current.CancellationToken);

        Assert.Equal(["web-1"], found.Select(agent => agent.Metadata.Name));
    }

    [Fact]
    public async Task GetModelCatalogReadsTheDefaultCatalog()
    {
        server.Objects["/apis/agents.re-cinq.com/v1beta1/namespaces/ai-agents/modelcatalogs/default"] = JsonNode.Parse("""
            {"apiVersion":"agents.re-cinq.com/v1beta1","kind":"ModelCatalog","metadata":{"name":"default"},
             "status":{"vendors":[{"vendor":"claude","models":[{"id":"claude-opus-5-5"}]}]}}
            """)!.AsObject();

        var catalog = await new AgentContractsClient(server.Client()).GetModelCatalogAsync(TestContext.Current.CancellationToken);

        Assert.Equal("claude-opus-5-5", catalog.Status!.Vendors![0].Models![0].Id);
    }

    [Fact]
    public async Task ApplyStationSendsAForcedApplyPatchInTheClientNamespace()
    {
        var station = new Station
        {
            Metadata = new V1ObjectMeta { Name = "story-writer", ManagedFields = [new V1ManagedFieldsEntry { Manager = "kubectl" }] },
            Spec = new StationSpec { AgentDefRef = "story-writer", Template = new JsonObject { ["spec"] = new JsonObject() } },
        };

        var applied = await new AgentContractsClient(server.Client(), "team-a").ApplyStationAsync(station, TestContext.Current.CancellationToken);

        var patch = Assert.Single(server.Patches);
        Assert.Equal(
            ("/apis/agents.re-cinq.com/v1beta1/namespaces/team-a/stations/story-writer?fieldManager=agent-contracts&force=true", "application/apply-patch+yaml"),
            (patch.PathAndQuery, patch.ContentType));
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("""
            {"apiVersion":"agents.re-cinq.com/v1beta1","kind":"Station","metadata":{"name":"story-writer","namespace":"team-a"},
             "spec":{"agentDefRef":"story-writer","template":{"spec":{}}}}
            """), patch.Body), patch.Body.ToJsonString());
        Assert.Equal("story-writer", applied.Spec!.AgentDefRef);
    }

    [Fact]
    public async Task ApplyAgentDefinitionReturnsTheAppliedDefinition()
    {
        var definition = new AgentDefinition
        {
            Metadata = new V1ObjectMeta { Name = "story-writer" },
            Spec = new AgentDefinitionSpec { Model = "claude-opus-5-5", Prompt = "Write a story." },
        };

        var applied = await new AgentContractsClient(server.Client()).ApplyAgentDefinitionAsync(definition, TestContext.Current.CancellationToken);

        Assert.Equal("claude-opus-5-5", applied.Spec!.Model);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public async Task ApplyStationWithoutANameFails(string? name)
    {
        var station = new Station { Metadata = new V1ObjectMeta { Name = name } };

        var error = await Assert.ThrowsAsync<ArgumentException>(() =>
            new AgentContractsClient(server.Client()).ApplyStationAsync(station, TestContext.Current.CancellationToken));

        Assert.Equal("apply Station: metadata.name is required (Parameter 'resource')", error.Message);
    }

    [Fact]
    public async Task WaitForAgentReturnsTheRunOnceItSucceeds()
    {
        var agents = new AgentContractsClient(server.Client());
        await agents.CreateAgentAsync(AgentNamed("run-1", Phase.Running), TestContext.Current.CancellationToken);
        var waiting = agents.WaitForAgentAsync("run-1", TimeSpan.FromMilliseconds(10), TestContext.Current.CancellationToken);
        lock (server.Objects)
        {
            server.Objects[$"{Agents}/run-1"]["status"]!["phase"] = "Succeeded";
        }

        var finished = await waiting;

        Assert.Equal(Phase.Succeeded, finished.Status!.Phase);
    }

    [Fact]
    public async Task WaitForAgentStopsWhenCancelledWhileRunning()
    {
        var agents = new AgentContractsClient(server.Client());
        await agents.CreateAgentAsync(AgentNamed("run-1", Phase.Running), TestContext.Current.CancellationToken);
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            agents.WaitForAgentAsync("run-1", TimeSpan.FromMilliseconds(10), timeout.Token));
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData(Phase.Pending, false)]
    [InlineData(Phase.Running, false)]
    [InlineData(Phase.Succeeded, true)]
    [InlineData(Phase.Failed, true)]
    public void IsTerminalIsTrueOnlyForSucceededAndFailed(Phase? phase, bool terminal)
    {
        var agent = new Agent { Status = phase is null ? null : new AgentStatus { Phase = phase } };

        Assert.Equal(terminal, AgentContractsClient.IsTerminal(agent));
    }
}
