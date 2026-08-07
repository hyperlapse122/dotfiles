#!/usr/bin/env bun
/**
 * Stub OpenAI-completions-shaped model server for the credential-free
 * real-omp runtime proof (docs/plans/feedback-sweep-plan.md KTD5, unit U7,
 * R2, gh-issues:hyperlapse122/dotfiles#171).
 *
 * Binds an ephemeral port on 127.0.0.1, prints that port as its only stdout
 * line so the caller can capture it, then serves a scripted two-turn
 * tool-call conversation over `POST /v1/chat/completions` in omp's
 * `openai-completions` streaming dialect: omp sends `stream: true`, so every
 * response here is `text/event-stream` carrying `data: {...chunk...}` lines
 * and a final `data: [DONE]`.
 *
 *   - A request whose message history has no `tool`-role message yet (the
 *     conversation's first turn) gets back a streaming `tool_calls` delta
 *     naming TOOL_NAME with TOOL_ARGUMENTS_JSON, followed by a
 *     `finish_reason: "tool_calls"` chunk. This is what drives omp's own
 *     extension resolution and tool dispatch: the caller never invents a
 *     tool call locally, omp does, against its own real tool list.
 *   - A request that already carries a `tool`-role message (the second
 *     turn, after omp has executed the tool for real and reported the
 *     result back) gets back that tool result's content, *verbatim*, as a
 *     plain assistant message, followed by `finish_reason: "stop"`, so the
 *     session terminates. This mirrors what a real model asked to "report
 *     verbatim" the tool's output would do, and is what lets the caller
 *     assert on the guard's block reason (or the managed-path allow)
 *     directly in omp's own printed text.
 *
 * Every request is appended to LOG_FILE as one JSON line recording the tool
 * names present in the request's own `tools` array, so a caller can assert
 * the server was actually reached and that omp's real tool list -- not a
 * hand-rolled one -- reached the wire. A server that is never contacted
 * leaves LOG_FILE empty, which the caller must treat as a failure.
 *
 * Usage: bun stub-model-server.ts LOG_FILE TOOL_NAME TOOL_ARGUMENTS_JSON
 */

import { appendFileSync } from "node:fs";

const [, , logFile, toolName, toolArguments] = process.argv;
if (!logFile || !toolName || !toolArguments) {
  console.error("usage: stub-model-server.ts LOG_FILE TOOL_NAME TOOL_ARGUMENTS_JSON");
  process.exit(1);
}

type ChatMessage = { role?: string; content?: unknown };
type ChatCompletionRequest = {
  messages?: ChatMessage[];
  tools?: Array<{ function?: { name?: string } }>;
};

let seq = 0;

function sseResponse(chunks: unknown[]): Response {
  const body = chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, {
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return new Response("stub-model-server: not found", { status: 404 });
    }

    seq += 1;
    let payload: ChatCompletionRequest;
    try {
      payload = await req.json();
    } catch (error) {
      appendFileSync(logFile, `${JSON.stringify({ seq, error: `invalid JSON body: ${String(error)}` })}\n`);
      return new Response("stub-model-server: invalid JSON body", { status: 400 });
    }

    const tools = (payload.tools ?? [])
      .map((tool) => tool.function?.name)
      .filter((name): name is string => Boolean(name));
    const toolResult = (payload.messages ?? []).findLast((message) => message.role === "tool");
    appendFileSync(logFile, `${JSON.stringify({ seq, tools, hasToolResult: Boolean(toolResult) })}\n`);

    const id = `chatcmpl-stub-${seq}`;
    const created = Math.floor(Date.now() / 1000);
    const base = { id, object: "chat.completion.chunk" as const, created, model: "stub-1" };

    if (!toolResult) {
      return sseResponse([
        {
          ...base,
          choices: [
            {
              index: 0,
              delta: {
                role: "assistant",
                tool_calls: [
                  { index: 0, id: "call_stub_1", type: "function", function: { name: toolName, arguments: toolArguments } },
                ],
              },
              finish_reason: null,
            },
          ],
        },
        { ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      ]);
    }

    const reportText = typeof toolResult.content === "string" ? toolResult.content : JSON.stringify(toolResult.content);
    return sseResponse([
      { ...base, choices: [{ index: 0, delta: { role: "assistant", content: reportText }, finish_reason: null }] },
      { ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
    ]);
  },
});

console.log(server.port);
