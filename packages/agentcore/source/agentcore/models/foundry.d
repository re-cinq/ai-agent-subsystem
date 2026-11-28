module agentcore.models.foundry;

import std.algorithm : filter, map;
import std.array : array, join;
import std.exception : enforce;
import std.format : format;
import vibe.data.json : Json;

import agentcore.batch.provider : HttpRequest, HttpResponse, HttpTransport;
import agentcore.core.vendor : Vendor;
import agentcore.crds.model_catalog : ModelInfo;

version (unittest)
{
	import fluent.asserts;
}

/// The models a Foundry resource answered for, and the error that stopped the probe ("" when none did).
struct FoundryProbe
{
	ModelInfo[] models;
	string error;
}

/// Probes each of `modelIds` on the Foundry resource at `endpoint`: a 404 drops the model (not deployed),
/// a 401, 403 or 5xx is an error naming it, any other status (a 429 included) keeps it.
FoundryProbe probeFoundryModels(Vendor vendor, string endpoint, string apiKey, string[] modelIds,
	HttpTransport transport)
{
	auto answers = modelIds
		.map!(modelId => ModelAnswer(modelId, transport(probeRequest(vendor, endpoint, apiKey, modelId))))
		.array;
	return FoundryProbe(
		answers.filter!(answer => answer.response.status != 404 && !answer.failed)
			.map!(answer => ModelInfo(answer.modelId, answer.modelId)).array,
		answers.filter!(answer => answer.failed)
			.map!(answer => format!"%s: HTTP %s: %s"(answer.modelId, answer.response.status, answer.response.body))
			.join("; "));
}

private struct ModelAnswer
{
	string modelId;
	HttpResponse response;

	bool failed() const
	{
		return response.status == 401 || response.status == 403 || response.status >= 500;
	}
}

/// The request that proves `modelId` is deployed on the Foundry resource at `endpoint`.
HttpRequest probeRequest(Vendor vendor, string endpoint, string apiKey, string modelId)
{
	final switch (vendor)
	{
	case Vendor.claude:
		return HttpRequest("POST", endpoint ~ "/v1/messages",
			["api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json"],
			format!`{"model":%s,"max_tokens":1,"messages":[{"role":"user","content":"ping"}]}`(Json(modelId).toString()));
	case Vendor.codex:
		return HttpRequest("POST", endpoint ~ "/responses",
			["api-key": apiKey, "content-type": "application/json"],
			format!`{"model":%s,"input":"ping","max_output_tokens":16}`(Json(modelId).toString()));
	case Vendor.gemini:
	case Vendor.exec:
	case Vendor.opencode:
		enforce(false, format!"no Foundry probe for vendor %s"(vendor));
		assert(0);
	}
}

version (unittest)
{
	private struct FakeTransport
	{
		HttpResponse[] responses;
		HttpRequest[] requests;

		HttpResponse send(HttpRequest request)
		{
			requests ~= request;
			const response = responses[0];
			responses = responses[1 .. $];
			return response;
		}
	}
}

unittest // claude probes POST /v1/messages per model and keeps claude-sonnet-5-5, dropping claude-opus-5-5 which answers 404
{
	auto transport = FakeTransport([HttpResponse(404, `{"error":{"code":"DeploymentNotFound"}}`),
		HttpResponse(200, `{"id":"msg_1"}`)]);

	probeFoundryModels(Vendor.claude, "https://my-foundry.services.ai.azure.com/anthropic", "foundry-key",
		["claude-opus-5-5", "claude-sonnet-5-5"], &transport.send).should.equal(
		FoundryProbe([ModelInfo("claude-sonnet-5-5", "claude-sonnet-5-5")], ""));
	transport.requests.should.equal([
		HttpRequest("POST", "https://my-foundry.services.ai.azure.com/anthropic/v1/messages",
			["api-key": "foundry-key", "anthropic-version": "2023-06-01", "content-type": "application/json"],
			`{"model":"claude-opus-5-5","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}`),
		HttpRequest("POST", "https://my-foundry.services.ai.azure.com/anthropic/v1/messages",
			["api-key": "foundry-key", "anthropic-version": "2023-06-01", "content-type": "application/json"],
			`{"model":"claude-sonnet-5-5","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}`)
	]);
}

unittest // a 401 for claude-opus-5-5 is the probe's error and a 429 for claude-sonnet-5-5 still proves its deployment
{
	auto transport = FakeTransport([HttpResponse(401, `{"error":{"code":"401","message":"Access denied"}}`),
		HttpResponse(429, `{"error":{"code":"429"}}`)]);

	probeFoundryModels(Vendor.claude, "https://my-foundry.services.ai.azure.com/anthropic", "foundry-key",
		["claude-opus-5-5", "claude-sonnet-5-5"], &transport.send).should.equal(
		FoundryProbe([ModelInfo("claude-sonnet-5-5", "claude-sonnet-5-5")],
		`claude-opus-5-5: HTTP 401: {"error":{"code":"401","message":"Access denied"}}`));
}

unittest // codex probes POST /responses per model and keeps gpt-5.1-codex, dropping gpt-5.1 which answers 404
{
	auto transport = FakeTransport([HttpResponse(404, `{"error":{"code":"DeploymentNotFound"}}`),
		HttpResponse(200, `{"id":"resp_1"}`)]);

	probeFoundryModels(Vendor.codex, "https://my-foundry.openai.azure.com/openai/v1", "foundry-key",
		["gpt-5.1", "gpt-5.1-codex"], &transport.send).should.equal(
		FoundryProbe([ModelInfo("gpt-5.1-codex", "gpt-5.1-codex")], ""));
	transport.requests.should.equal([
		HttpRequest("POST", "https://my-foundry.openai.azure.com/openai/v1/responses",
			["api-key": "foundry-key", "content-type": "application/json"],
			`{"model":"gpt-5.1","input":"ping","max_output_tokens":16}`),
		HttpRequest("POST", "https://my-foundry.openai.azure.com/openai/v1/responses",
			["api-key": "foundry-key", "content-type": "application/json"],
			`{"model":"gpt-5.1-codex","input":"ping","max_output_tokens":16}`)
	]);
}
