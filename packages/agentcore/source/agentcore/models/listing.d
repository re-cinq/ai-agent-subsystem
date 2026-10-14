module agentcore.models.listing;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.exception : enforce;
import std.format : format;
import std.string : chompPrefix;
import std.uri : encodeComponent;
import vibe.data.json : Json, parseJsonString;

import agentcore.batch.provider : HttpRequest, HttpTransport;
import agentcore.core.vendor : Vendor, vendorOf;
import agentcore.crds.model_catalog : ModelInfo;

version (unittest)
{
	import agentcore.batch.provider : HttpResponse;
	import fluent.asserts;
}

/// Every model `vendor`'s list-models API reports for `apiKey`, across all pages, kept only
/// when the subsystem routes its id back to `vendor` — an id it would hand another CLI
/// (a `gemma-*` from Gemini, a `dall-e-*` from OpenAI) is not runnable as that vendor.
ModelInfo[] listModels(Vendor vendor, string apiKey, HttpTransport transport)
{
	ModelInfo[] models;
	string cursor;
	do
	{
		auto request = pageRequest(vendor, apiKey, cursor);
		const response = transport(request);
		enforce(response.status >= 200 && response.status < 300,
			format!"%s %s: HTTP %s: %s"(request.method, request.url, response.status, response.body));
		const page = parsePage(vendor, parseJsonString(response.body));
		models ~= page.models;
		cursor = page.next;
	}
	while (cursor.length);
	return models.filter!(model => vendorOf(model.id) == vendor).array;
}

/// One page of a vendor's model list, and the cursor of the next page ("" on the last).
struct ModelPage
{
	ModelInfo[] models;
	string next;
}

/// The list-models request for the page at `cursor` ("" for the first), authenticated with `apiKey`.
HttpRequest pageRequest(Vendor vendor, string apiKey, string cursor) @safe
{
	final switch (vendor)
	{
	case Vendor.claude:
		return HttpRequest("GET", anthropicModelsUrl ~ (cursor.length ? "&after_id=" ~ encodeComponent(cursor) : ""),
			["x-api-key": apiKey, "anthropic-version": anthropicVersion]);
	case Vendor.codex:
		return HttpRequest("GET", openaiModelsUrl, ["authorization": "Bearer " ~ apiKey]);
	case Vendor.gemini:
		return HttpRequest("GET", geminiModelsUrl ~ (cursor.length ? "&pageToken=" ~ encodeComponent(cursor) : ""),
			["x-goog-api-key": apiKey]);
	case Vendor.exec:
	case Vendor.opencode:
		enforce(false, format!"no list-models API for vendor %s"(vendor));
		assert(0);
	}
}

/// Read one page of `vendor`'s list-models response.
ModelPage parsePage(Vendor vendor, Json page)
{
	final switch (vendor)
	{
	case Vendor.claude:
		return ModelPage(entries(page, "data").map!(model => ModelInfo(model["id"].get!string,
				model["display_name"].opt!string(""))).array,
			page["has_more"].opt!bool(false) ? page["last_id"].get!string : "");
	case Vendor.codex:
		return ModelPage(entries(page, "data").map!(model => ModelInfo(model["id"].get!string,
				model["id"].get!string)).array);
	case Vendor.gemini:
		return ModelPage(entries(page, "models").filter!(model => generatesContent(model))
				.map!(model => ModelInfo(model["name"].get!string.chompPrefix("models/"),
					model["displayName"].opt!string(""))).array,
			page["nextPageToken"].opt!string(""));
	case Vendor.exec:
	case Vendor.opencode:
		enforce(false, format!"no list-models API for vendor %s"(vendor));
		assert(0);
	}
}

private Json[] entries(Json page, string key)
{
	return page[key].opt!(Json[])(null);
}

/// Whether a Gemini model answers `generateContent` — the call the Gemini CLI makes;
/// embedding and AQA models do not.
private bool generatesContent(Json model)
{
	return model["supportedGenerationMethods"].opt!(Json[])(null).canFind(Json("generateContent"));
}

private enum anthropicModelsUrl = "https://api.anthropic.com/v1/models?limit=1000";
private enum anthropicVersion = "2023-06-01";
private enum openaiModelsUrl = "https://api.openai.com/v1/models";
private enum geminiModelsUrl = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000";

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

unittest // claude follows has_more with after_id and lists claude-opus-5-5, claude-sonnet-5-5 and claude-haiku-5-5
{
	auto transport = FakeTransport([HttpResponse(200, import("models/anthropic-page-1.json")),
		HttpResponse(200, import("models/anthropic-page-2.json"))]);

	listModels(Vendor.claude, "sk-ant-test", &transport.send).should.equal([
		ModelInfo("claude-opus-5-5", "Claude Opus 5.5"), ModelInfo("claude-sonnet-5-5", "Claude Sonnet 5.5"),
		ModelInfo("claude-haiku-5-5", "Claude Haiku 5.5")
	]);
	transport.requests.should.equal([
		HttpRequest("GET", "https://api.anthropic.com/v1/models?limit=1000",
			["x-api-key": "sk-ant-test", "anthropic-version": "2023-06-01"]),
		HttpRequest("GET", "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-sonnet-5-5",
			["x-api-key": "sk-ant-test", "anthropic-version": "2023-06-01"])
	]);
}

unittest // codex keeps gpt-5.1-codex, gpt-5.1 and o4-mini and drops text-embedding-3-small, dall-e-3 and whisper-1
{
	auto transport = FakeTransport([HttpResponse(200, import("models/openai.json"))]);

	listModels(Vendor.codex, "sk-test", &transport.send).should.equal([
		ModelInfo("gpt-5.1-codex", "gpt-5.1-codex"), ModelInfo("gpt-5.1", "gpt-5.1"), ModelInfo("o4-mini", "o4-mini")
	]);
	transport.requests.should.equal([
		HttpRequest("GET", "https://api.openai.com/v1/models", ["authorization": "Bearer sk-test"])
	]);
}

unittest // gemini follows nextPageToken and keeps generateContent gemini models, dropping the embedding and gemma models
{
	auto transport = FakeTransport([HttpResponse(200, import("models/gemini-page-1.json")),
		HttpResponse(200, import("models/gemini-page-2.json"))]);

	listModels(Vendor.gemini, "AIza-test", &transport.send).should.equal([
		ModelInfo("gemini-3.1-pro", "Gemini 3.1 Pro"), ModelInfo("gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite")
	]);
	transport.requests.should.equal([
		HttpRequest("GET", "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000",
			["x-goog-api-key": "AIza-test"]),
		HttpRequest("GET", "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&pageToken=Cg%2Bnext",
			["x-goog-api-key": "AIza-test"])
	]);
}

unittest // a 401 answer throws naming the request and the error body
{
	auto transport = FakeTransport([HttpResponse(401, `{"error":"invalid x-api-key"}`)]);

	listModels(Vendor.claude, "sk-ant-bad", &transport.send).should.throwException!Exception.withMessage(
		`GET https://api.anthropic.com/v1/models?limit=1000: HTTP 401: {"error":"invalid x-api-key"}`);
}

unittest // opencode has no list-models API
{
	pageRequest(Vendor.opencode, "key", "").should.throwException!Exception.withMessage(
		"no list-models API for vendor opencode");
}
