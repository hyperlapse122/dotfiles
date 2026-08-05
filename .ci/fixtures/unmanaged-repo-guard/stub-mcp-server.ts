/**
 * Minimal stdio MCP server (plan U7 / KTD3). Registers as the `glab` server
 * so its one tool resolves as `mcp__glab_issue_create`, matching the guard's
 * MCP allowlist entry (`triggers.ts` `MCP_ISSUE_WRITE_TOOLS`). Every reply on
 * the handshake path (`initialize`, `tools/list`) is synchronous with no
 * async I/O, so it lands inside omp's 250ms MCP fast-startup gate; the
 * per-call log append is a synchronous `appendFileSync`, not an async
 * operation, for the same reason.
 *
 * `tools/call` is the causal proof for U7's block half: the guard's
 * `tool_call` hook fires before the underlying tool executes, so a blocked
 * call never reaches `tools/call` at all - log absence proves the block,
 * log presence proves pass-through (plan KTD2, mirroring the existing `gh`
 * stub's `GH_LOG`). `tools/list` is logged too, so registration is asserted
 * directly rather than assumed (plan KTD3).
 *
 * Required env: STUB_MCP_LOG - path to the JSONL invocation log.
 */

import { appendFileSync } from "node:fs";

const logPath = process.env["STUB_MCP_LOG"];
if (!logPath) {
  process.stderr.write("STUB_MCP_LOG unset\n");
  process.exit(1);
}

const PROTOCOL_VERSION = "2025-03-26";

const ISSUE_CREATE_TOOL = {
  name: "issue_create",
  description: "Create an issue against a repository (stub, plan U7).",
  inputSchema: {
    type: "object",
    properties: {
      repo: { type: "string" },
      title: { type: "string" },
      body: { type: "string" },
    },
    required: ["repo", "title", "body"],
  },
};

// Only the fields the assertions need, mirroring the existing `gh` stub's
// GH_LOG: never raw stdio frames, so nothing beyond what U7's assertions
// read lands on disk.
function logEntry(entry: Record<string, unknown>): void {
  appendFileSync(logPath, `${JSON.stringify({ time: new Date().toISOString(), ...entry })}\n`);
}

function writeMessage(message: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function handleRequest(id: unknown, method: string, params: Record<string, unknown>): void {
  if (method === "initialize") {
    writeMessage({
      jsonrpc: "2.0",
      id,
      result: {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "stub-mcp-server", version: "0.0.0" },
      },
    });
    return;
  }
  if (method === "tools/list") {
    logEntry({ event: "tools/list" });
    writeMessage({ jsonrpc: "2.0", id, result: { tools: [ISSUE_CREATE_TOOL] } });
    return;
  }
  if (method === "tools/call") {
    const name = params["name"];
    const args = params["arguments"];
    logEntry({ event: "tools/call", tool: name, arguments: args });
    const repo = typeof args === "object" && args !== null ? (args as Record<string, unknown>)["repo"] : undefined;
    writeMessage({
      jsonrpc: "2.0",
      id,
      result: { content: [{ type: "text", text: `Created issue (stub) for ${String(repo ?? "unknown repo")}` }], isError: false },
    });
    return;
  }
  writeMessage({ jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } });
}

function handleLine(line: string): void {
  if (line.trim() === "") return;
  let message: { jsonrpc?: string; id?: unknown; method?: string; params?: Record<string, unknown> };
  try {
    message = JSON.parse(line);
  } catch {
    return; // Malformed line: dropped, matching the client-side stdio transport's own tolerance.
  }
  if (typeof message.method !== "string") return;
  if ("id" in message && message.id !== undefined) {
    handleRequest(message.id, message.method, message.params ?? {});
  }
  // Notifications (no id) - including `notifications/initialized` - need no reply.
}

let buffer = "";
for await (const chunk of process.stdin) {
  buffer += chunk.toString("utf8");
  let newlineIndex = buffer.indexOf("\n");
  while (newlineIndex !== -1) {
    handleLine(buffer.slice(0, newlineIndex));
    buffer = buffer.slice(newlineIndex + 1);
    newlineIndex = buffer.indexOf("\n");
  }
}
