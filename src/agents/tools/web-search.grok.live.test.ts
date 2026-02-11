import { describe, expect, it } from "vitest";
import { isTruthyEnvValue } from "../../infra/env.js";
import { __testing } from "./web-search.js";

const LIVE = isTruthyEnvValue(process.env.OPENCLAW_LIVE_TEST) || isTruthyEnvValue(process.env.LIVE);
const XAI_KEY = process.env.XAI_API_KEY?.trim() ?? "";
const GROK_MODEL = process.env.OPENCLAW_LIVE_GROK_MODEL?.trim() || "grok-4-1-fast";
const XAI_RESPONSES_API = "https://api.x.ai/v1/responses";

type ParsedResponse = {
  text?: string;
  annotationCitations?: string[];
};

const describeLive = LIVE && XAI_KEY ? describe : describe.skip;

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is string => typeof item === "string" && item.length > 0);
}

function legacyExtractText(data: unknown): string | undefined {
  if (!data || typeof data !== "object") {
    return undefined;
  }
  const value = (data as { output?: Array<{ content?: Array<{ text?: unknown }> }> }).output?.[0]
    ?.content?.[0]?.text;
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function normalizeExtractResult(raw: unknown): {
  text: string | undefined;
  annotationCitations: string[];
} {
  if (typeof raw === "string") {
    return { text: raw, annotationCitations: [] };
  }
  if (!raw || typeof raw !== "object") {
    return { text: undefined, annotationCitations: [] };
  }
  const parsed = raw as ParsedResponse;
  return {
    text: typeof parsed.text === "string" ? parsed.text : undefined,
    annotationCitations: asStringArray(parsed.annotationCitations),
  };
}

async function callXaiResponses(params: {
  body: Record<string, unknown>;
  timeoutMs: number;
}): Promise<{ status: number; ok: boolean; data?: Record<string, unknown>; detail?: string }> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), params.timeoutMs);
  timeout.unref?.();
  try {
    const res = await fetch(XAI_RESPONSES_API, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${XAI_KEY}`,
      },
      body: JSON.stringify(params.body),
      signal: controller.signal,
    });
    if (!res.ok) {
      return { status: res.status, ok: false, detail: await res.text() };
    }
    return { status: res.status, ok: true, data: (await res.json()) as Record<string, unknown> };
  } finally {
    clearTimeout(timeout);
  }
}

describeLive("web_search grok live", () => {
  it("extracts text from xAI Responses API payloads", async () => {
    const request: Record<string, unknown> = {
      model: GROK_MODEL,
      input: [
        {
          role: "user",
          content:
            "Search the web for the latest OpenAI API docs URL. Reply in one sentence and include source links.",
        },
      ],
      tools: [{ type: "web_search" }],
      include: ["inline_citations"],
    };

    let result = await callXaiResponses({ body: request, timeoutMs: 45_000 });
    if (
      !result.ok &&
      result.status === 400 &&
      typeof result.detail === "string" &&
      result.detail.includes("Argument not supported: include")
    ) {
      const retryRequest = { ...request };
      delete retryRequest.include;
      result = await callXaiResponses({ body: retryRequest, timeoutMs: 45_000 });
    }

    expect(result.ok, result.detail ?? "xAI request failed").toBe(true);
    const data = result.data as Record<string, unknown>;
    const parsed = normalizeExtractResult(__testing.extractGrokContent(data as never));
    const legacyText = legacyExtractText(data);

    expect(parsed.text && parsed.text.trim().length > 0).toBe(true);
    if (!legacyText) {
      expect(parsed.text && parsed.text.trim().length > 0).toBe(true);
    }
  }, 60_000);
});
