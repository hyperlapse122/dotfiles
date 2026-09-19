---
title: Unattended Agent Harness Workspace Trust Seeding
date: 2026-09-12
last_updated: 2026-09-19
category: integration-issues
module: agents
problem_type: integration_issue
component: agent_workspaces
symptoms:
  - "opening a worktree in claude or codex prompts for interactive trust confirmation"
  - "unattended agent runs (lfg, codex exec, orca dispatch) stall or run in degraded mode when entering fresh worktrees"
  - "parent directories like ~/src or ~/.local/share/worktrees cannot be trusted via prefix wildcards"
root_cause: design_limitation
resolution_type: tooling_addition
severity: medium
tags:
  - claude
  - codex
  - orca
  - worktree
  - trust
---

# Unattended Agent Harness Workspace Trust Seeding

## Problem
Agent harnesses (`claude`, `codex`) require operator confirmation before trusting a project directory. In automated pipelines (`lfg`, `codex exec`, background coordinators, or Orca-dispatched workers), no human is present to accept trust dialogs. The session either stalls awaiting input or falls back to an untrusted sandbox mode. (Antigravity CLI `agy` formerly required trust seeding as well, but has since been retired.)

Because neither harness supports directory prefix wildcards or recursive parent trust:
- `claude` inspects ancestors only up to the git repository root (`~/.claude.json`).
- `codex` requires exact string match in `[projects."<abs-path>"]` (`~/.codex/config.toml`).

## Solution

A dual-point trust seeding architecture:
1. **Apply-Time Discovery:**
   `home/.chezmoiscripts/90-src/run_after_trust-agent-worktrees.sh.tmpl` invokes `agent-trust-reconcile --all`, which forwards to `settings-reconcile trust --all` (implemented in native TypeScript in `packages/settings-reconcile`). Discovery reads registered checkout paths in O(1) time from `~/.config/garden/garden.yaml` paired with a single-depth scan of `~/.local/share/worktrees/*`, eliminating recursive `os.walk` traversal. Trust is asserted additively into `~/.claude.json` and `~/.codex/config.toml`.
2. **Worktree Creation Interception:**
   `orca-ide` is wrapped via `home/dot_local/share/chezmoi-command-sources/executable_orca-ide` managed in `home/.chezmoidata/commands.yaml`. When `worktree create` exits 0, the wrapper extracts the newly created worktree path and invokes `agent-trust-reconcile <path>`, delegating directly to `settings-reconcile trust <path>`.

All mutations preserve existing unrelated settings and prior trust entries atomically with `0600` permissions.
