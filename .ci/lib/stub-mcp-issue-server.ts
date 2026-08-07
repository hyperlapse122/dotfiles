#!/usr/bin/env bun
/**
 * Minimal stdio MCP server exposing one tool, `issue_create`, for the
 * subagent MCP-call proof (docs/plans/feedback-sweep-plan.md unit U8, R8,
 * gh-issues:hyperlapse122/dotfiles#177).
 *
 * Registered in the relocated HOME's mcp.json under the server name "glab",
 * so omp mints the runtime tool name `mcp__glab_issue_create` (confirmed
 * empirically against the locked omp version; see the plan's U8 execution
 * note).
 *
 * Speaks newline-delimited JSON-RPC 2.0 over stdio directly (the MCP stdio
 * wire format: one JSON object per line, no Content-Length framing), with
 * no SDK dependency, mirroring stub-model-server.ts's zero-dependency,
 * no-build-step convention.
 *
 * Every `tools/call` invocation of `issue_create` is appended to
 * MCP_ISSUE_LOG (an env var the caller sets on this server's entry in
 * mcp.json, the same way the `gh` stub uses GH_LOG) as one JSON line, so
 * the caller can prove the call did or did not reach this process across
 * the omp -> MCP subprocess boundary.
 */

import { appendFileSync } from "node:fs";

const logFile = process.env.MCP_ISSUE_LOG;
if (!logFile) {
  console.error("stub-mcp-issue-server: MCP_ISSUE_LOG is unset");
  process.exit(1);
}

const TOOL_NAME = "issue_create";

type JsonRpcId = number | string;
type JsonRpcRequest = { jsonrpc: "2.0"; id?: JsonRpcId; method: string; params?: unknown };
type CallToolParams = { name?: string; arguments?: unknown };

function send(message: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function respond(id: JsonRpcId, result: unknown): void {
  send({ jsonrpc: "2.0", id, result });
}

function respondError(id: JsonRpcId, code: number, message: string): void {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function handleInitialize(id: JsonRpcId, params: unknown): void {
  const requested = typeof params === "object" && params !== null ? (params as { protocolVersion?: unknown }).protocolVersion : undefined;
  respond(id, {
    protocolVersion: typeof requested === "string" ? requested : "2024-11-05",
    capabilities: { tools: {} },
    serverInfo: { name: "stub-mcp-issue-server", version: "0.0.0" },
  });
}

function handleListTools(id: JsonRpcId): void {
  respond(id, {
    tools: [
      {
        name: TOOL_NAME,
        description: "Create an issue in a repository (stub).",
        inputSchema: {
          type: "object",
          properties: {
            repo: { type: "string" },
            title: { type: "string" },
            body: { type: "string" },
          },
          required: ["repo", "title"],
        },
      },
    ],
  });
}

function handleCallTool(id: JsonRpcId, params: unknown, log: string): void {
  const call: CallToolParams = typeof params === "object" && params !== null ? params : {};
  if (call.name !== TOOL_NAME) {
    respondError(id, -32602, `stub-mcp-issue-server: unknown tool ${JSON.stringify(call.name)}`);
    return;
  }
  appendFileSync(log, `${JSON.stringify({ tool: call.name, arguments: call.arguments ?? null })}\n`);
  respond(id, {
    content: [{ type: "text", text: "https://github.com/other-owner/other-repo/issues/998" }],
    isError: false,
  });
}

let buffer = "";
process.stdin.on("data", (chunk: Buffer) => {
  buffer += chunk.toString("utf8");
  let newlineIndex: number;
  while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, newlineIndex).replace(/\r$/, "");
    buffer = buffer.slice(newlineIndex + 1);
    if (!line.trim()) continue;

    let message: JsonRpcRequest;
    try {
      message = JSON.parse(line) as JsonRpcRequest;
    } catch (error) {
      console.error(`stub-mcp-issue-server: invalid JSON-RPC line: ${String(error)}`);
      continue;
    }

    if (message.id === undefined) continue; // notification: no response due

    switch (message.method) {
      case "initialize":
        handleInitialize(message.id, message.params);
        break;
      case "tools/list":
        handleListTools(message.id);
        break;
      case "tools/call":
        handleCallTool(message.id, message.params, logFile);
        break;
      case "ping":
        respond(message.id, {});
        break;
      default:
        respondError(message.id, -32601, `stub-mcp-issue-server: unhandled method ${message.method}`);
    }
  }
});

process.stdin.on("end", () => process.exit(0));
