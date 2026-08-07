#!/usr/bin/env bun
/**
 * Stub OpenAI-completions-shaped model server for the credential-free
 * real-omp runtime proof (docs/plans/feedback-sweep-plan.md KTD5; units U7
 * R2 gh-issues:hyperlapse122/dotfiles#171, and U8 R8
 * gh-issues:hyperlapse122/dotfiles#177).
 *
 * Binds an ephemeral port on 127.0.0.1, prints that port as its only stdout
 * line so the caller can capture it, then serves one of two scripted
 * conversations over `POST /v1/chat/completions` in omp's
 * `openai-completions` streaming dialect: omp sends `stream: true`, so every
 * response here is `text/event-stream` carrying `data: {...chunk...}` lines
 * and a final `data: [DONE]`.
 *
 * The caller selects the conversation via the required STUB_SCENARIO
 * environment variable:
 *
 *   - "bash" (U7): a two-turn, single-session conversation. Argv is
 *     LOG_FILE TOOL_NAME TOOL_ARGUMENTS_JSON. Turn one (no `tool`-role
 *     message yet) returns a streaming `tool_calls` delta naming TOOL_NAME
 *     with TOOL_ARGUMENTS_JSON. Turn two (a `tool`-role message is already
 *     present) echoes that tool result's content verbatim as a plain
 *     assistant message and stops.
 *
 *   - "subagent" (U8): a five-turn, two-session conversation proving a
 *     *subagent's own* MCP tool call is intercepted, not just a top-level
 *     one. Argv is LOG_FILE PARENT_PROMPT_TEXT. Containment on the
 *     request's `tools` list cannot tell the parent session from the child:
 *     omp mounts `mcp__glab_issue_create` for *both* once
 *     `tools.xdev: false` is set (needed so the tool is offered directly
 *     rather than folded behind the `xd://` device transport -- confirmed
 *     empirically, see the plan's U8 execution note), and the child still
 *     carries `task` (recursion is allowed one level deep). So every
 *     request is instead classified by its *last user message text*, which
 *     is exact and known up front for both sessions:
 *       - the parent's is PARENT_PROMPT_TEXT, fixed by the caller (the
 *         test's own prompt to omp);
 *       - the child's is `Complete the assignment below, thoroughly:\n\n`
 *         + CHILD_TASK_TEXT -- the fixed prefix omp's built-in `task` agent
 *         wraps around a spawned subagent's own first user message
 *         (confirmed empirically), plus CHILD_TASK_TEXT below, which this
 *         server itself chose when it emitted the `task` call.
 *     A request whose last user message matches neither is a hard error
 *     (HTTP 500 plus a logged `error` entry): a silent fallthrough here is
 *     exactly how this proof could pass without checking anything.
 *
 *     Turn sequence (by the last-user-message tag and the count of
 *     `tool`-role messages already in the conversation):
 *       1. parent, 0 tool results -> calls `task`, spawning one subagent
 *          whose task text is CHILD_TASK_TEXT.
 *       2. parent, 1 tool result  -> calls `hub` with `op: "wait"`, which
 *          blocks the parent's own turn loop until the spawned job settles
 *          (the CLI process does not otherwise wait for a background job:
 *          confirmed empirically -- omp's `task` tool is fire-and-forget).
 *       3. child, 0 tool results  -> calls `mcp__glab_issue_create`
 *          directly, targeting `other-owner/other-repo` (the same target
 *          the "bash" scenario's `gh issue create` uses).
 *       4. child, 1 tool result   -> calls `yield`, reporting that tool
 *          result's content verbatim as its subagent result.
 *       5. parent, 2 tool results -> the `hub wait` result (which embeds
 *          the child's yielded report) is echoed verbatim as a plain
 *          assistant message and the session stops -- mirroring "bash"'s
 *          echo-and-stop turn, so the caller can assert on the guard's
 *          block reason (or the managed-path allow) directly in omp's own
 *          printed text, exactly as it already does for "bash".
 *
 * Every request is appended to LOG_FILE as one JSON line recording the tool
 * names present in the request's own `tools` array (so a caller can assert
 * the server was actually reached and that omp's real tool list -- not a
 * hand-rolled one -- reached the wire), plus, for "subagent", the resolved
 * `tag` ("parent" | "child") and how many `tool`-role messages preceded it.
 * A caller can therefore recover the ordered parent/child request sequence
 * straight from LOG_FILE. A server that is never contacted leaves LOG_FILE
 * empty, which the caller must treat as a failure.
 *
 * Usage:
 *   STUB_SCENARIO=single-tool bun stub-model-server.ts LOG_FILE TOOL_NAME TOOL_ARGUMENTS_JSON
 *   STUB_SCENARIO=subagent  bun stub-model-server.ts LOG_FILE PARENT_PROMPT_TEXT
 */

import { appendFileSync } from "node:fs";

type ChatMessage = { role?: string; content?: unknown };
type ChatCompletionRequest = {
  messages?: ChatMessage[];
  tools?: Array<{ function?: { name?: string } }>;
};

/** The text a spawned subagent's own first user message is wrapped in. */
const CHILD_TASK_PREFIX = "Complete the assignment below, thoroughly:\n\n";
/** Fixed by this server itself, per the module doc comment above. */
const CHILD_TASK_TEXT =
  'Run exactly one mcp__glab_issue_create tool call targeting repo "other-owner/other-repo", ' +
  'title "test issue", body "test body". Do not run any other tool call. Report verbatim whatever ' +
  "that single call returns.";
const MCP_TOOL_NAME = "mcp__glab_issue_create";

const scenario = process.env.STUB_SCENARIO;
if (scenario !== "single-tool" && scenario !== "subagent") {
  console.error("usage: STUB_SCENARIO=single-tool|subagent bun stub-model-server.ts ...");
  process.exit(1);
}

const [, , logFile, ...rest] = process.argv;
if (!logFile) {
  console.error("usage: bun stub-model-server.ts LOG_FILE ...");
  process.exit(1);
}

let seq = 0;

function sseResponse(chunks: unknown[]): Response {
  const body = chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, {
    headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
  });
}

/** One streaming tool-call delta chunk followed by its `finish_reason: "tool_calls"` chunk. */
function toolCallResponse(base: Record<string, unknown>, name: string, args: string): Response {
  return sseResponse([
    {
      ...base,
      choices: [
        {
          index: 0,
          delta: {
            role: "assistant",
            tool_calls: [{ index: 0, id: "call_stub_1", type: "function", function: { name, arguments: args } }],
          },
          finish_reason: null,
        },
      ],
    },
    { ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
  ]);
}

/** A plain assistant message echoing `text` verbatim, then `finish_reason: "stop"`. */
function stopResponse(base: Record<string, unknown>, text: string): Response {
  return sseResponse([
    { ...base, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] },
    { ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
  ]);
}

function textOf(content: unknown): string {
  return typeof content === "string" ? content : JSON.stringify(content);
}

type ContentBlock = { type?: string; text?: string };

/**
 * omp sends a `user`-role message's content as an array of
 * `{type:"text", text}` blocks even for a single plain-text message (never
 * a bare string), so the last-user-message match below needs this instead
 * of `textOf`, which is for `tool`-role results (already plain strings).
 */
function userText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((block: unknown) => {
      const text = (block as ContentBlock | undefined)?.text;
      return typeof text === "string" ? text : "";
    })
    .join("");
}

function chunkBase(): Record<string, unknown> {
  seq += 1;
  return { id: `chatcmpl-stub-${seq}`, object: "chat.completion.chunk" as const, created: Math.floor(Date.now() / 1000), model: "stub-1" };
}

type ParsedChatRequest = { payload: ChatCompletionRequest; tools: string[] };

/**
 * Parse the request body and extract its offered tool names, logging and
 * returning null on invalid JSON so the caller can respond 400. Shared by
 * every scenario handler below.
 */
async function parseChatRequest(req: Request, logFile: string): Promise<ParsedChatRequest | null> {
  let payload: ChatCompletionRequest;
  try {
    payload = await req.json();
  } catch (error) {
    appendFileSync(logFile, `${JSON.stringify({ seq, error: `invalid JSON body: ${String(error)}` })}\n`);
    return null;
  }
  const tools = (payload.tools ?? []).map((tool) => tool.function?.name).filter((name): name is string => Boolean(name));
  return { payload, tools };
}

async function handleSingleTool(req: Request, logFile: string, toolName: string, toolArguments: string): Promise<Response> {
  const base = chunkBase();
  const parsed = await parseChatRequest(req, logFile);
  if (!parsed) return new Response("stub-model-server: invalid JSON body", { status: 400 });
  const { payload, tools } = parsed;

  const toolResult = (payload.messages ?? []).findLast((message) => message.role === "tool");
  appendFileSync(logFile, `${JSON.stringify({ seq, tools, hasToolResult: Boolean(toolResult) })}\n`);

  if (!toolResult) return toolCallResponse(base, toolName, toolArguments);
  return stopResponse(base, textOf(toolResult.content));
}

async function handleSubagent(req: Request, logFile: string, parentPromptText: string): Promise<Response> {
  const base = chunkBase();
  const parsed = await parseChatRequest(req, logFile);
  if (!parsed) return new Response("stub-model-server: invalid JSON body", { status: 400 });
  const { payload, tools } = parsed;

  const messages = payload.messages ?? [];
  const lastUser = messages.findLast((message) => message.role === "user");
  const lastUserText = userText(lastUser?.content);
  const toolResults = messages.filter((message) => message.role === "tool");

  const childText = CHILD_TASK_PREFIX + CHILD_TASK_TEXT;
  const tag = lastUserText === parentPromptText ? "parent" : lastUserText === childText ? "child" : null;
  if (tag === null) {
    appendFileSync(logFile, `${JSON.stringify({ seq, tools, error: "last user message matched neither known text", lastUserText })}\n`);
    console.error(`stub-model-server: unrecognized last user message for seq ${seq}: ${JSON.stringify(lastUserText)}`);
    return new Response("stub-model-server: unrecognized last user message text", { status: 500 });
  }
  appendFileSync(logFile, `${JSON.stringify({ seq, tag, tools, toolMsgCount: toolResults.length })}\n`);

  if (tag === "parent") {
    if (toolResults.length === 0) {
      const args = JSON.stringify({ i: "spawn mcp probe", context: "u8 real-runtime proof", tasks: [{ task: CHILD_TASK_TEXT }] });
      return toolCallResponse(base, "task", args);
    }
    if (toolResults.length === 1) return toolCallResponse(base, "hub", JSON.stringify({ op: "wait", i: "wait for subagent" }));
    return stopResponse(base, textOf(toolResults.at(-1)?.content));
  }

  // tag === "child"
  if (toolResults.length === 0) {
    const args = JSON.stringify({ repo: "other-owner/other-repo", title: "test issue", body: "test body" });
    return toolCallResponse(base, MCP_TOOL_NAME, args);
  }
  const report = { data: { report: textOf(toolResults.at(-1)?.content) } };
  return toolCallResponse(base, "yield", JSON.stringify({ result: report }));
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(req) {
    const url = new URL(req.url);
    if (req.method !== "POST" || url.pathname !== "/v1/chat/completions") {
      return new Response("stub-model-server: not found", { status: 404 });
    }
    if (scenario === "single-tool") {
      const [toolName, toolArguments] = rest;
      if (!toolName || !toolArguments) {
        console.error("usage: STUB_SCENARIO=single-tool bun stub-model-server.ts LOG_FILE TOOL_NAME TOOL_ARGUMENTS_JSON");
        process.exit(1);
      }
      return handleSingleTool(req, logFile, toolName, toolArguments);
    }
    const [parentPromptText] = rest;
    if (!parentPromptText) {
      console.error("usage: STUB_SCENARIO=subagent bun stub-model-server.ts LOG_FILE PARENT_PROMPT_TEXT");
      process.exit(1);
    }
    return handleSubagent(req, logFile, parentPromptText);
  },
});

console.log(server.port);
