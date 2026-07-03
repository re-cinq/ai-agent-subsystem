import { describe, it, expect } from "vitest";
import { enforce, enforceHTTPSuccess } from "./enforce.js";

describe("enforce", () => {
  it("returns the value when it is truthy", () => {
    expect(enforce("run-abc", "unused")).toBe("run-abc");
  });

  it("throws the message when the value is undefined", () => {
    expect(() => enforce(undefined, "metadata.name is required")).toThrow(
      new Error("metadata.name is required"),
    );
  });

  it("throws the message when the value is an empty string", () => {
    expect(() => enforce("", "metadata.name is required")).toThrow(
      new Error("metadata.name is required"),
    );
  });
});

describe("enforceHTTPSuccess", () => {
  it("returns the body when status is 200", () => {
    expect(enforceHTTPSuccess({ status: 200, body: { items: [] } })).toEqual({ items: [] });
  });

  it("returns the body when status is 299", () => {
    expect(enforceHTTPSuccess({ status: 299, body: "ok" })).toBe("ok");
  });

  it("throws with status and body when status is 404", () => {
    expect(() => enforceHTTPSuccess({ status: 404, body: { message: "not found" } })).toThrow(
      new Error('kube request failed (404): {"message":"not found"}'),
    );
  });

  it("throws when status is 199", () => {
    expect(() => enforceHTTPSuccess({ status: 199, body: null })).toThrow(
      /kube request failed \(199\)/,
    );
  });

  it("throws when status is 300", () => {
    expect(() => enforceHTTPSuccess({ status: 300, body: null })).toThrow(
      /kube request failed \(300\)/,
    );
  });
});
