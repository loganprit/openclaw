import { beforeEach, describe, expect, it, vi } from "vitest";
import { addSubagentRunForTests, resetSubagentRegistryForTests } from "./subagent-registry.js";
import { createSessionsSpawnTool } from "./tools/sessions-spawn-tool.js";

const callGatewayMock = vi.fn();

vi.mock("../gateway/call.js", () => ({
  callGateway: (opts: unknown) => callGatewayMock(opts),
}));

let configOverride: Record<string, unknown> = {
  session: {
    mainKey: "main",
    scope: "per-sender",
  },
};

vi.mock("../config/config.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../config/config.js")>();
  return {
    ...actual,
    loadConfig: () => configOverride,
  };
});

describe("sessions_spawn depth + child limits", () => {
  beforeEach(() => {
    resetSubagentRegistryForTests();
    callGatewayMock.mockReset();
    configOverride = {
      session: {
        mainKey: "main",
        scope: "per-sender",
      },
    };

    callGatewayMock.mockImplementation(async (opts: unknown) => {
      const req = opts as { method?: string };
      if (req.method === "agent") {
        return { runId: "run-depth" };
      }
      if (req.method === "agent.wait") {
        return { status: "running" };
      }
      return {};
    });
  });

  it("rejects spawning when caller depth reaches maxSpawnDepth", async () => {
    const tool = createSessionsSpawnTool({ agentSessionKey: "agent:main:subagent:parent" });
    const result = await tool.execute("call-depth-reject", { task: "hello" });

    expect(result.details).toMatchObject({
      status: "forbidden",
      error: "sessions_spawn is not allowed at this depth (current depth: 1, max: 1)",
    });
  });

  it("allows depth-1 callers when maxSpawnDepth is 2", async () => {
    configOverride = {
      session: {
        mainKey: "main",
        scope: "per-sender",
      },
      agents: {
        defaults: {
          subagents: {
            maxSpawnDepth: 2,
          },
        },
      },
    };

    const tool = createSessionsSpawnTool({ agentSessionKey: "agent:main:subagent:parent" });
    const result = await tool.execute("call-depth-allow", { task: "hello" });

    expect(result.details).toMatchObject({
      status: "accepted",
      childSessionKey: expect.stringMatching(/^agent:main:subagent:/),
      runId: "run-depth",
    });

    const agentCall = callGatewayMock.mock.calls
      .map((call) => call[0] as { method?: string; params?: Record<string, unknown> })
      .find((entry) => entry.method === "agent");
    expect(agentCall?.params?.spawnedBy).toBe("agent:main:subagent:parent");
  });

  it("rejects depth-2 callers when maxSpawnDepth is 2", async () => {
    configOverride = {
      session: {
        mainKey: "main",
        scope: "per-sender",
      },
      agents: {
        defaults: {
          subagents: {
            maxSpawnDepth: 2,
          },
        },
      },
    };

    const tool = createSessionsSpawnTool({
      agentSessionKey: "agent:main:subagent:parent:subagent:child",
    });
    const result = await tool.execute("call-depth-2-reject", { task: "hello" });

    expect(result.details).toMatchObject({
      status: "forbidden",
      error: "sessions_spawn is not allowed at this depth (current depth: 2, max: 2)",
    });
  });

  it("rejects when active children for requester session reached maxChildrenPerAgent", async () => {
    configOverride = {
      session: {
        mainKey: "main",
        scope: "per-sender",
      },
      agents: {
        defaults: {
          subagents: {
            maxSpawnDepth: 2,
            maxChildrenPerAgent: 1,
          },
        },
      },
    };

    addSubagentRunForTests({
      runId: "existing-run",
      childSessionKey: "agent:main:subagent:existing",
      requesterSessionKey: "agent:main:subagent:parent",
      requesterDisplayKey: "agent:main:subagent:parent",
      task: "existing",
      cleanup: "keep",
      createdAt: Date.now(),
      startedAt: Date.now(),
    });

    const tool = createSessionsSpawnTool({ agentSessionKey: "agent:main:subagent:parent" });
    const result = await tool.execute("call-max-children", { task: "hello" });

    expect(result.details).toMatchObject({
      status: "forbidden",
      error: "sessions_spawn has reached max active children for this session (1/1)",
    });
  });
});
