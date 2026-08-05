/**
 * Credential-free stub OpenAI-compatible chat-completions server (plan U6,
 * extended by U7). Drives omp's REAL model dispatch with no model
 * credential: it answers by matching request CONTENT, never by counting
 * turns (plan KTD1, KTD2, Assumptions). Every response is a well-formed
 * OpenAI tool-call payload or a well-formed terminal response, so an
 * unscripted request can never hang the run or desync a scripted turn.
 *
 * Usage: bun stub-model-server.ts <script.json>
 * Required env: STUB_MODEL_LOG - path to the JSONL request log (mirrors the
 * existing gh stub's GH_LOG).
 *
 * <script.json> shape:
 *   { "rules": [ { "id": string, "match": string, "tool": string, "arguments": unknown } ] }
 *
 * Matching order, content-based (never a turn counter):
 *   1. The request's last message carries a tool result (`role: "tool"`) ->
 *      always a plain `stop` response. Checked FIRST, so a stale substring
 *      match sitting in an earlier turn's text can never re-fire a tool call
 *      out of order.
 *   2. Otherwise, the first script rule whose `match` substring appears in
 *      the request's non-tool message text, AND whose `tool` name is among
 *      this request's declared `tools`, wins - matching only a name the
 *      request actually declared keeps a background-role request (no tools
 *      declared at all) from ever accidentally matching a scripted rule.
 *   3. Anything else - a background-role request (session title, memory
 *      extraction, thinking-difficulty classification) or an omp subagent
 *      "you forgot to yield" reminder - gets a well-formed terminal response
 *      with empty content. This catch-all is what keeps an unscripted
 *      request from hanging the run or consuming a scripted turn out of
 *      order (plan stop condition (d), determinism).
 *
 * Streaming: openai-completions is a streaming transport, so every response
 * is emitted as OpenAI chat-completion-chunk SSE frames terminated by
 * `data: [DONE]`, mirroring `stream_options.include_usage` when requested.
 * A non-streaming request (`stream` absent or false) gets a single JSON
 * response instead, so the stub degrades gracefully either way.
 */

import { appendFileSync } from "node:fs";

const scriptPath = Bun.argv[2];
if (!scriptPath) {
  console.error("usage: stub-model-server.ts <script.json>");
  process.exit(1);
}
const logPath = process.env["STUB_MODEL_LOG"];
if (!logPath) {
  console.error("STUB_MODEL_LOG unset");
  process.exit(1);
}

type ScriptRule = { id: string; match: string; tool: string; arguments: unknown };
type Script = { rules: ScriptRule[] };

const script: Script = JSON.parse(await Bun.file(scriptPath).text());
if (!Array.isArray(script.rules) || script.rules.length === 0) {
  console.error(`${scriptPath}: no rules declared`);
  process.exit(1);
}

type ChatMessage = { role: string; content?: unknown };
type ChatRequest = {
  model?: string;
  messages?: ChatMessage[];
  tools?: Array<{ type?: string; function?: { name?: string } }>;
  stream?: boolean;
  stream_options?: { include_usage?: boolean };
};

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === "string") return part;
        if (part && typeof part === "object" && typeof (part as Record<string, unknown>)["text"] === "string") {
          return (part as Record<string, unknown>)["text"] as string;
        }
        return "";
      })
      .join("\n");
  }
  return "";
}

// Only the fields the assertions need - never headers, never raw message
// bodies, so an ambient credential the runtime happens to attach cannot
// land on disk (plan U6 approach step 2).
function logEntry(entry: Record<string, unknown>): void {
  appendFileSync(logPath, `${JSON.stringify({ time: new Date().toISOString(), ...entry })}\n`);
}

function randomId(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, "")}`;
}

const NO_USAGE = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };

/** One decided turn: either a scripted tool call, or a plain terminal reply. */
type Decision =
  | { kind: "tool_call"; id: string; tool: string; argumentsJson: string }
  | { kind: "terminal"; content: string; finishReason: "stop" };

function decide(body: ChatRequest): { decision: Decision; logFields: Record<string, unknown> } {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const last = messages[messages.length - 1];
  const declaredTools = new Set(
    (Array.isArray(body.tools) ? body.tools : [])
      .map((t) => t?.function?.name)
      .filter((name): name is string => typeof name === "string"),
  );

  // KTD2 rule: a request carrying a tool result always concludes the turn.
  // A subagent conversation must conclude through the hidden `yield` tool -
  // declared only for child sessions - rather than plain text, or omp
  // reminds the child to continue and the guarded call retries out of
  // turn, breaking KTD2's "exactly one entry per observed block" audit
  // count (plan U7 approach step 3's "child's conclusion").
  if (last && last.role === "tool") {
    const toolResultText = textOf(last.content);
    const logFields = { matchedRule: null, toolNames: [] as string[], toolResultText, catchAll: false };
    if (declaredTools.has("yield")) {
      return {
        decision: { kind: "tool_call", id: randomId("call"), tool: "yield", argumentsJson: JSON.stringify({ result: { data: {} } }) },
        logFields: { ...logFields, toolNames: ["yield"] },
      };
    }
    return { decision: { kind: "terminal", content: "OK.", finishReason: "stop" }, logFields };
  }

  const haystack = messages
    .filter((m) => m.role !== "tool")
    .map((m) => textOf(m.content))
    .join("\n");

  const rule = script.rules.find((r) => haystack.includes(r.match) && declaredTools.has(r.tool));
  if (rule) {
    return {
      decision: { kind: "tool_call", id: randomId("call"), tool: rule.tool, argumentsJson: JSON.stringify(rule.arguments) },
      logFields: { matchedRule: rule.id, toolNames: [rule.tool], toolResultText: null, catchAll: false },
    };
  }

  // Catch-all: a background-role request (session title, memory extraction,
  // thinking-difficulty classification) or an omp subagent "you forgot to
  // yield" reminder. Never hangs, never guesses.
  return {
    decision: { kind: "terminal", content: "", finishReason: "stop" },
    logFields: { matchedRule: null, toolNames: [], toolResultText: null, catchAll: true },
  };
}

function nonStreamingResponse(model: string, decision: Decision): Response {
  const message: Record<string, unknown> =
    decision.kind === "tool_call"
      ? {
          role: "assistant",
          content: null,
          tool_calls: [{ id: decision.id, type: "function", function: { name: decision.tool, arguments: decision.argumentsJson } }],
        }
      : { role: "assistant", content: decision.content };
  const finishReason = decision.kind === "tool_call" ? "tool_calls" : decision.finishReason;
  return Response.json({
    id: randomId("chatcmpl"),
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message, finish_reason: finishReason }],
    usage: NO_USAGE,
  });
}

function streamingResponse(model: string, decision: Decision, includeUsage: boolean): Response {
  const id = randomId("chatcmpl");
  const created = Math.floor(Date.now() / 1000);
  const chunk = (delta: Record<string, unknown>, finishReason: string | null) => ({
    id,
    object: "chat.completion.chunk",
    created,
    model,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  });
  const frames: Record<string, unknown>[] = [];
  frames.push(chunk({ role: "assistant" }, null));
  if (decision.kind === "tool_call") {
    frames.push(
      chunk({ tool_calls: [{ index: 0, id: decision.id, type: "function", function: { name: decision.tool, arguments: "" } }] }, null),
    );
    frames.push(chunk({ tool_calls: [{ index: 0, function: { arguments: decision.argumentsJson } }] }, null));
    frames.push(chunk({}, "tool_calls"));
  } else {
    if (decision.content !== "") frames.push(chunk({ content: decision.content }, null));
    frames.push(chunk({}, decision.finishReason));
  }
  if (includeUsage) frames.push({ id, object: "chat.completion.chunk", created, model, choices: [], usage: NO_USAGE });

  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const encoder = new TextEncoder();
      for (const frame of frames) controller.enqueue(encoder.encode(`data: ${JSON.stringify(frame)}\n\n`));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
  return new Response(body, { headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return new Response("not found", { status: 404 });
    }

    let body: ChatRequest;
    try {
      body = (await req.json()) as ChatRequest;
    } catch {
      return Response.json({ error: { message: "invalid JSON body" } }, { status: 400 });
    }

    const model = typeof body.model === "string" && body.model !== "" ? body.model : "stub-model";
    const { decision, logFields } = decide(body);
    logEntry(logFields);

    if (body.stream === true) {
      return streamingResponse(model, decision, body.stream_options?.include_usage === true);
    }
    return nonStreamingResponse(model, decision);
  },
});

// Printed so the launching shell can capture the ephemeral port (plan U6
// approach step 1).
console.log(String(server.port));
