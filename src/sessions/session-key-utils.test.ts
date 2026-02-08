import { describe, expect, it } from "vitest";
import { getSubagentDepth } from "./session-key-utils.js";

describe("getSubagentDepth", () => {
  it("returns 0 for non-subagent session keys", () => {
    expect(getSubagentDepth("agent:main:main")).toBe(0);
    expect(getSubagentDepth("main")).toBe(0);
    expect(getSubagentDepth(undefined)).toBe(0);
  });

  it("returns 1 for depth-1 subagent session keys", () => {
    expect(getSubagentDepth("agent:main:subagent:123")).toBe(1);
  });

  it("returns 2 for nested subagent session keys", () => {
    expect(getSubagentDepth("agent:main:subagent:parent:subagent:child")).toBe(2);
  });
});
