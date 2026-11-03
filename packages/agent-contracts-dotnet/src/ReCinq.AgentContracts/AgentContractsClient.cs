using k8s;
using k8s.Models;

namespace ReCinq.AgentContracts;

/// <summary>
/// Creates and reads the subsystem's resources in one namespace through the official
/// <see cref="IKubernetes"/> client.
/// </summary>
public sealed class AgentContractsClient
{
    /// <summary>The namespace the subsystem installs into and runs Agents in.</summary>
    public const string DefaultNamespace = "ai-agents";

    private const string FieldManager = "agent-contracts";
    private const string ModelCatalogName = "default";

    private readonly IKubernetes kube;
    private readonly string targetNamespace;

    /// <summary>A client for <paramref name="namespace"/>, or <see cref="DefaultNamespace"/> when it is null or empty.</summary>
    public AgentContractsClient(IKubernetes kube, string? @namespace = null)
    {
        this.kube = kube;
        targetNamespace = string.IsNullOrEmpty(@namespace) ? DefaultNamespace : @namespace;
    }

    /// <summary>Starts one run in the client's namespace.</summary>
    public Task<Agent> CreateAgentAsync(Agent agent, CancellationToken cancellationToken = default)
    {
        agent.Metadata.NamespaceProperty = targetNamespace;
        return kube.CustomObjects.CreateNamespacedCustomObjectAsync<Agent>(
            agent, ApiGroup.Group, ApiGroup.Version, targetNamespace, Agent.Plural,
            cancellationToken: cancellationToken);
    }

    /// <summary>Reads one run; the API's 404 surfaces as an <c>HttpOperationException</c>.</summary>
    public Task<Agent> GetAgentAsync(string name, CancellationToken cancellationToken = default) =>
        kube.CustomObjects.GetNamespacedCustomObjectAsync<Agent>(
            ApiGroup.Group, ApiGroup.Version, targetNamespace, Agent.Plural, name, cancellationToken);

    /// <summary>Lists the runs matching a Kubernetes label selector such as <c>team=web</c>.</summary>
    public async Task<IList<Agent>> FindAgentsAsync(string labelSelector, CancellationToken cancellationToken = default)
    {
        var list = await kube.CustomObjects.ListNamespacedCustomObjectAsync<AgentList>(
            ApiGroup.Group, ApiGroup.Version, targetNamespace, Agent.Plural,
            labelSelector: labelSelector, cancellationToken: cancellationToken).ConfigureAwait(false);
        return list.Items;
    }

    /// <summary>Reads the models the subsystem can run (the controller's <c>default</c> ModelCatalog).</summary>
    public Task<ModelCatalog> GetModelCatalogAsync(CancellationToken cancellationToken = default) =>
        kube.CustomObjects.GetNamespacedCustomObjectAsync<ModelCatalog>(
            ApiGroup.Group, ApiGroup.Version, targetNamespace, ModelCatalog.Plural, ModelCatalogName, cancellationToken);

    /// <summary>Server-side applies an AgentDefinition, taking over fields other managers set.</summary>
    public Task<AgentDefinition> ApplyAgentDefinitionAsync(AgentDefinition definition, CancellationToken cancellationToken = default) =>
        ApplyAsync(definition, AgentDefinition.Plural, cancellationToken);

    /// <summary>Server-side applies a Station, taking over fields other managers set.</summary>
    public Task<Station> ApplyStationAsync(Station station, CancellationToken cancellationToken = default) =>
        ApplyAsync(station, Station.Plural, cancellationToken);

    private Task<T> ApplyAsync<T>(T resource, string plural, CancellationToken cancellationToken)
        where T : IKubernetesObject<V1ObjectMeta>
    {
        var name = resource.Metadata.Name;
        if (string.IsNullOrEmpty(name))
        {
            throw new ArgumentException($"apply {resource.Kind}: metadata.name is required", nameof(resource));
        }
        resource.Metadata.NamespaceProperty = targetNamespace;
        resource.Metadata.ManagedFields = null;
        return kube.CustomObjects.PatchNamespacedCustomObjectAsync<T>(
            new V1Patch(resource, V1Patch.PatchType.ApplyPatch), ApiGroup.Group, ApiGroup.Version,
            targetNamespace, plural, name, fieldManager: FieldManager, force: true, cancellationToken: cancellationToken);
    }

    /// <summary>Whether a run has finished (Succeeded or Failed).</summary>
    public static bool IsTerminal(Agent agent) =>
        agent.Status?.Phase is Phase.Succeeded or Phase.Failed;

    /// <summary>
    /// Polls the run every <paramref name="interval"/> until it is Succeeded or Failed. It never gives
    /// up on its own: cancel <paramref name="cancellationToken"/> (for example with a timeout) to bound the wait.
    /// </summary>
    public async Task<Agent> WaitForAgentAsync(string name, TimeSpan interval, CancellationToken cancellationToken = default)
    {
        while (true)
        {
            var agent = await GetAgentAsync(name, cancellationToken).ConfigureAwait(false);
            if (IsTerminal(agent))
            {
                return agent;
            }
            await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        }
    }
}
