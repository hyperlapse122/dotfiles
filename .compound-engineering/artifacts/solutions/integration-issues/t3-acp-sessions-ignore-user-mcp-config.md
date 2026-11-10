---
title: T3 Code's ACP agent sessions ignore user-level MCP config, so a declared MCP server reaches only their terminal sessions
date: "2026-10-29"
category: integration-issues
module: MCP server registration across agent harnesses and T3 Code providers
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "OMP run by T3 Code has no fff tools although ~/.omp/agent/mcp.json declares the fff server"
  - "tests/omp_settings_applied.py passes, because it reads the restored mcp.json rather than asking an ACP session for its tools"
  - "agent-settings refuses ~/.gemini/config/mcp_config.json with 'settings file is not valid JSON' on a fresh Antigravity CLI install"
root_cause: config_error
resolution_type: config_change
related_components:
  - documentation
retire_when: "The pinned OMP stops forcing enableMCP false in its ACP session factory, or T3 Code gains a user-declared MCP server list it sends in session/new"
tags: ["mcp", "acp", "t3code", "omp", "antigravity", "fff", "agent-settings", "session-new"]
---

# T3 Code's ACP agent sessions ignore user-level MCP config, so a declared MCP server reaches only their terminal sessions

## Problem

The fff MCP server was registered in every harness's user-level MCP config so that every agent session, including T3 Code's delegated ones, could use it. Two T3 Code providers run their agent over ACP, and an ACP agent takes its MCP servers from the client rather than from disk, so those sessions never see the declaration.

## Symptoms

- T3 Code's OMP instance starts with no fff tools, even after activation wrote `~/.omp/agent/mcp.json` with the fff entry.
- The T3 Code `antigravity` instance has no fff tools either.
- The repository's OMP check stays green, because it checks the file and not the session.
- Separately, the first merge into a fresh Antigravity CLI MCP file failed: the CLI creates `~/.gemini/config/mcp_config.json` as a 0-byte file, and `json.loads('')` raises.

## What Didn't Work

- Planning assumed T3 Code's OMP instance would read `~/.omp/agent/mcp.json` like OMP's terminal sessions, because its `--config` flag only adds a settings scope (`home/h82/t3code.nix:68-72`). The flag was never the issue. ACP mode itself skips MCP discovery.
- Reading the restored `mcp.json` in `tests/omp_settings_applied.py` proves the file, not the consumer. The same gap appears in [the Antigravity ACP runtime loads no global rule files](antigravity-acp-runtime-loads-no-global-rule-files.md): a delivered file looks like a working delivery in every materialized-output check.

## Solution

Declare the server where each harness's terminal sessions read it, and treat the ACP-driven T3 sessions as out of reach from this repository:

| Harness | User-level file | Reaches the T3 Code instance? |
| --- | --- | --- |
| Claude Code | `~/.claude.json` `mcpServers` | Yes: T3 Claude sessions load the user settings source |
| Codex | `~/.codex/config.toml` `mcp_servers` | Yes: the T3 instance uses `homePath = "~/.codex"` (`home/h82/t3code.nix`) |
| OMP | `~/.omp/agent/mcp.json` | No: T3 runs it with `--mode acp` |
| Antigravity CLI | `~/.gemini/config/mcp_config.json` | No: the T3 instance runs the ACP runtime |
| Grok Build | `~/.grok/config.toml` `mcp_servers` | Not checked |

For the empty file, `scripts/agent-settings` now reads an empty or whitespace-only JSON file as `{}` (`read_settings`), tested by `test_an_empty_file_merges_as_an_empty_object` in `tests/test_agent_settings.py`. A file with any other invalid content is still refused untouched.

## Why This Works

OMP's ACP session factory forces `enableMCP: false` on every session it creates, so `createAgentSession` skips the on-disk `.mcp.json` discovery. Its comment says MCP servers in ACP sessions are owned exclusively by the ACP client, and that host MCP tools would otherwise shadow the client's servers. This is `createAcpSessionFactory` in upstream OMP's [`main.ts` at the pinned commit](https://github.com/can1357/oh-my-pi/blob/e996e1c7ac476f60e02b8ed9764cf30fa8c00a8e/packages/coding-agent/src/main.ts), the commit `packages/omp-release.json` pins. The ACP agent then builds its MCP configuration only from the `mcpServers` the client sends in `session/new`. The Antigravity ACP binary takes the same `session/new` parameter and reads no user MCP file. T3 Code sends only its own orchestration server there, and the pinned release has no setting for extra user servers. So no file this repository writes reaches those sessions.

## Prevention

- Before promising that a declared MCP server, rule file, or setting reaches a T3 Code provider, find out whether that provider is an ACP agent. If it is, the client decides what the agent gets; check what T3 Code sends, not what the agent reads on its own.
- Prove an ACP consumer with a live `session/new` call that lists the session's tools, not with a check on a materialized file.
- Seed a 0-byte file in any merge test whose target file another tool creates before it writes anything.

## Related

- [The Antigravity ACP runtime loads no global rule files](antigravity-acp-runtime-loads-no-global-rule-files.md)
- [A T3 Code setting declared in settings.json outranks every repository's t3.json](t3code-settings-json-value-outranks-repository-t3-json.md)
- Plan: `.compound-engineering/artifacts/plans/2026-10-29-1020-feat-fff-agent-search-plan.md` (KTD4, KTD6, U4)
