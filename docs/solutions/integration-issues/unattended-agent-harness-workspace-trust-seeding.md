---
title: Unattended Agent Harness Workspace Trust Seeding
date: 2026-09-12
last_updated: 2026-09-12
category: integration-issues
module: agents
problem_type: integration_issue
component: agent_workspaces
symptoms:
  - "opening a worktree in claude, codex, or agy prompts for interactive trust confirmation"
  - "unattended agent runs (lfg, codex exec, orca dispatch) stall or run in degraded mode when entering fresh worktrees"
  - "parent directories like ~/src or ~/.local/share/worktrees cannot be trusted via prefix wildcards"
root_cause: design_limitation
resolution_type: feature
severity: medium
tags:
  - claude
  - codex
  - antigravity
  - orca
  - worktree
  - trust
---

# Unattended Agent Harness Workspace Trust Seeding

## Problem

Agent harnesses (`claude`, `codex`, `agy`) require operator confirmation before trusting a project directory. In automated pipelines (`lfg`, `codex exec`, background coordinators, or Orca-dispatched workers), no human is present to accept trust dialogs. The session either stalls awaiting input or falls back to an untrusted sandbox mode.

Because none of the three harnesses supports directory prefix wildcards or recursive parent trust:
- `claude` inspects ancestors only up to the git repository root (`~/.claude.json`).
- `codex` requires exact string match in `[projects."<abs-path>"]` (`~/.codex/config.toml`).
- `agy` requires exact string match in `trustedWorkspaces` (`~/.gemini/antigravity-cli/settings.json`).

## Solution

A dual-point trust seeding architecture:
1. **Apply-Time Discovery:**
   `.chezmoiscripts/90-src/run_after_trust-agent-worktrees.sh.tmpl` invokes `agent-trust-reconcile --all` on every `chezmoi apply`, discovering all repositories under `~/src` and `~/.local/share/worktrees` (pruning traversal at `.git` roots for sub-2ms discovery) and asserting trust additively into all three stores.
2. **Worktree Creation Interception:**
   `orca-ide` is wrapped via `dot_local/share/chezmoi-command-sources/executable_orca-ide` managed in `commands.yaml`. When `worktree create` exits 0, the wrapper extracts the newly created worktree path and invokes `agent-trust-reconcile <path>`.

All mutations preserve existing unrelated settings and prior trust entries atomically with `0600` permissions.
