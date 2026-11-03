using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using k8s;

namespace ReCinq.AgentContracts.Tests;

/// <summary>
/// An in-memory Kubernetes API server: a handler the real <see cref="Kubernetes"/> client sends its
/// requests to. It stores objects by path and records every PATCH.
/// </summary>
public sealed class FakeApiServer : DelegatingHandler
{
    public Dictionary<string, JsonObject> Objects { get; } = new();

    public List<(string PathAndQuery, string ContentType, JsonNode Body)> Patches { get; } = [];

    private int generated;

    public Kubernetes Client() => new(new KubernetesClientConfiguration { Host = "http://fake-api" }, this);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var path = request.RequestUri!.AbsolutePath;
        var query = request.RequestUri.Query;
        var body = request.Content is null ? null : JsonNode.Parse(await request.Content.ReadAsStringAsync(cancellationToken));
        lock (Objects)
        {
            var response = Handle(request.Method, path, query, request.Content?.Headers.ContentType?.MediaType ?? "", body);
            response.RequestMessage = request;
            return response;
        }
    }

    private HttpResponseMessage Handle(HttpMethod method, string path, string query, string contentType, JsonNode? body)
    {
        if (method == HttpMethod.Post)
        {
            var stored = body!.AsObject();
            var metadata = stored["metadata"]!.AsObject();
            if (metadata["name"] is null)
            {
                metadata["name"] = $"{metadata["generateName"]}{++generated}";
            }
            Objects[$"{path}/{metadata["name"]}"] = stored;
            return Reply(HttpStatusCode.Created, stored);
        }
        if (method == HttpMethod.Get && Objects.TryGetValue(path, out var found))
        {
            return Reply(HttpStatusCode.OK, found);
        }
        if (method == HttpMethod.Get && query.Contains("labelSelector="))
        {
            var selector = Uri.UnescapeDataString(query.Split("labelSelector=")[1].Split('&')[0]).Split('=');
            var items = new JsonArray(Objects
                .Where(entry => entry.Key.StartsWith(path + "/", StringComparison.Ordinal)
                    && entry.Value["metadata"]?["labels"]?[selector[0]]?.GetValue<string>() == selector[1])
                .Select(entry => (JsonNode)entry.Value.DeepClone())
                .ToArray());
            return Reply(HttpStatusCode.OK, new JsonObject { ["apiVersion"] = ApiGroup.ApiVersion, ["kind"] = "AgentList", ["metadata"] = new JsonObject(), ["items"] = items });
        }
        if (method == HttpMethod.Patch)
        {
            Patches.Add((path + query, contentType, body!.DeepClone()));
            Objects[path] = body!.AsObject();
            return Reply(HttpStatusCode.OK, body!);
        }
        return Reply(HttpStatusCode.NotFound, new JsonObject
        {
            ["kind"] = "Status", ["apiVersion"] = "v1", ["status"] = "Failure", ["reason"] = "NotFound", ["code"] = 404,
        });
    }

    private static HttpResponseMessage Reply(HttpStatusCode status, JsonNode body) => new(status)
    {
        Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
    };
}
