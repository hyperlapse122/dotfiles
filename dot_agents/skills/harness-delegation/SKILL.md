---
name: harness-delegation
description: >
  Playbook for delegating a task from the harness you are running in to
  another coding-agent CLI on this host — `pi`, `codex`, `agy`
  (Antigravity/Gemini), or `opencode` — via a non-interactive shell
  invocation. Load this BEFORE shelling out to any of those four binaries.
  Triggers: "delegate this to codex/pi/agy/opencode", "get a second opinion
  from another model", "have another agent review this diff", "run these in
  parallel", "offload this to a subagent CLI", "cross-model review", "use
  Gemini's big context for a whole-repo sweep", any `codex exec` / `opencode
  run` / `agy -p` / `pi -p` command line. It covers when delegation is (and
  is not) worth it, the harness-selection table, the ONE canonical
  non-interactive invocation per CLI, the self-contained prompt contract, the
  working-directory rule, the least-privilege escalation ladder, result
  verification, parallel fan-out, and the traps (agy's `-p` flag order above
  all). Exhaustive per-CLI flags, model catalogs, and output-capture recipes
  live in one reference per tool — `references/{pi,codex,agy,opencode}.md`; read
  the one for the harness you are about to invoke. Do NOT load it for spawning subagents
  INSIDE your own harness (that is your harness's own Task/Agent tool, not a
  shell-out), for branch/commit discipline (use `git-workflow`), or for
  PR/MR work (use `pr-mr`).
---

# Delegating to another agent harness

Four other coding-agent CLIs are installed on this host, each with its own
credentials, model catalog, and strengths. Delegation means shelling out to one
of them **non-interactively** and taking responsibility for what comes back.

**You remain accountable.** A delegate's claim of success is not completion —
core AGENTS.md's "Task completion — no silent deferral" guardrail binds *you*,
not the delegate. Verify (exit code + output + `git diff`) before accepting.

## When to delegate — and when not to

**SHOULD** delegate for **parallelism** (independent workstreams on *different*
files/worktrees), **a second opinion** (an adversarial review from a different
model family — the highest-value use), **long grinding work** you do not want to
spend your own context window on, or **a harness-specific strength** (table
below).

**MUST NOT** delegate work you can do faster inline (every delegation costs a
cold start, a self-contained brief, and a review pass), a hard problem you are
stuck on as a way to dodge it (delegating confusion returns confused output you
must then debug blind), or anything needing your conversational context — the
delegate shares **none** of it.

## Harness selection

| Need | Harness | Canonical command |
|---|---|---|
| Code review / second opinion on a diff | [`codex`](references/codex.md) | `codex exec review --uncommitted` (or `--base main`) |
| Independent analysis, read-only reasoning | [`codex`](references/codex.md) | `codex exec --sandbox read-only "<brief>"` |
| Huge-context sweep, whole-repo read, image/PDF/video input | [`agy`](references/agy.md) | `agy --model gemini-pro-agent -p "<brief>"` |
| Cheap/fast bulk analysis or a mechanical edit pass | [`pi`](references/pi.md) | `pi -p --model zai/glm-5.2 --no-session "<brief>"` |
| Structured multi-agent work (plan → execute → critique) | [`opencode`](references/opencode.md) | `opencode run --agent Prometheus "<brief>"` |

`agy` is Gemini: 1M-token context and native multimodal (image / pdf / audio /
video). `opencode`'s agent roster comes from the oh-my-openagent plugin —
`Prometheus` (plan) → `Atlas` (execute) → `Momus` (critic) / `oracle` (deep
reasoning).

**One reference per harness — read the one you are about to invoke** (flags,
model catalog, capture recipe, gotchas): [`references/pi.md`](references/pi.md) ·
[`references/codex.md`](references/codex.md) · [`references/agy.md`](references/agy.md) ·
[`references/opencode.md`](references/opencode.md).

## Trap #1 — `agy -p` TAKES THE PROMPT AS ITS VALUE

`agy` uses Go's `flag` package. `-p` / `--print` / `--prompt` is **not** a
boolean — the prompt is its **value**. Therefore **every other flag MUST come
BEFORE `-p`**:

```sh
agy --model gemini-pro-agent --print-timeout 20m -p "<brief>"   # CORRECT
agy -p --model gemini-pro-agent "<brief>"                       # BROKEN
```

The broken form does not error. `-p` swallows the literal string `--model` as
the prompt, `gemini-pro-agent` and the real brief are dropped as stray
positionals, and the agent wanders off inspecting its own CLI. Observed, not
theorized. The other three CLIs take the prompt positionally (`pi -p` and
`opencode`'s `-p` are unrelated flags — see the reference).

## The prompt contract — the brief MUST be self-contained

The delegate starts cold: no conversation, no plan, no file list. A brief
**MUST** carry:

1. The **absolute worktree path** and the branch it is on.
2. The **exact files in scope** — and an explicit **"do not touch X"**.
3. The **acceptance criteria** — how the delegate knows it is done.
4. The line: **"Do not commit, do not push, do not open a PR/MR."** Git
   discipline (branch naming, Conventional Commits, one-issue-one-MR) is the
   **caller's** — a delegate that commits bypasses every gate in core AGENTS.md.

**MUST NOT** paste tokens, keys, or secrets into a brief. Each harness has its
own credential store (core secrets guardrail).

**MUST NOT** instruct a delegate to itself delegate to another harness. No
recursion — you cannot verify what you cannot see.

## Working directory — a worktree, never a project root

A `~/src/<host>/[<group>/]<project>/` root is a bare repo plus worktrees; `git
status` fails there. **MUST** point the delegate at a **worktree**:

| Harness | How |
|---|---|
| `codex` | `-C/--cd <worktree>` |
| `opencode` | `--dir <worktree>` |
| `agy` | cwd; `--add-dir <path>` (repeatable) to widen the workspace |
| `pi` | cwd |

(See `src-layout` for the layout itself.)

## Escalation ladder — least privilege that can do the job

Default read-only; grant write **only** when the delegate must edit.

| Level | codex | agy | opencode | pi |
|---|---|---|---|---|
| Analyze / review | `--sandbox read-only` | `--mode plan` | (default; permissions preconfigured) | `--no-tools` |
| Edit in a worktree | `--sandbox workspace-write` | `--mode accept-edits` | (default) | (default) |
| Bypass everything | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` | `--auto` | — |

**There is NO `codex --full-auto` flag in this build** — `--sandbox
workspace-write` is how you let codex edit. **MUST NOT** pass
`--dangerously-bypass-approvals-and-sandbox`,
`--dangerously-bypass-hook-trust`, or `--dangerously-skip-permissions` without
an explicit user request **in the same turn** (core AGENTS.md destructive/bypass
guardrail). `opencode --auto` is rarely needed: its permissions are already set
in the repo-managed readonly `~/.config/opencode/opencode.json`.

## Verifying the result

A delegation is **FAILED** unless all three hold — **MUST** check every one:

1. **Exit code is 0.** All four exit 1 on a bad model id; a non-zero exit *or an
   empty final message* is a failure whatever the transcript claims.
2. **You read the output** (capture it, below) — not a summary of a summary.
3. **You reviewed `git diff`.** If the delegate edited anything, the diff is the
   only ground truth. An unverified claim of success is not completion.

## Capturing output

**MUST NOT** write scratch to `/tmp`, `/var/tmp`, or `/dev/shm` (core temp-file
rule; opencode's `scratch-guard` plugin actively denies those paths). Use
`"$XDG_RUNTIME_DIR/agent-scratch"` (or `~/.cache` when it is unset/large).

```sh
scratch="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"; mkdir -p "$scratch"
codex exec --sandbox read-only -C "$wt" -o "$scratch/codex.md" "<brief>"   # final answer ONLY
```

`codex exec` stdout carries a banner, a `tokens used` footer, and MCP stderr
noise (`ERROR rmcp::transport::worker: … Unexpected content type` is noise, not
failure) — **`-o/--output-last-message <FILE>` is the way to capture its
answer**. `pi -p` has the cleanest stdout of the four. JSON modes and their `jq`
filters → each harness's own reference ([pi](references/pi.md) ·
[codex](references/codex.md) · [agy](references/agy.md) ·
[opencode](references/opencode.md)).

## Parallel fan-out

Concurrent delegates **MUST NOT** be pointed at the same files or the same
worktree — racing edits corrupt each other silently.

```sh
scratch="${XDG_RUNTIME_DIR:-$HOME/.cache}/agent-scratch"; mkdir -p "$scratch"

codex exec --sandbox read-only -C ~/src/github.com/acme/api/main \
  -o "$scratch/codex.md" "Audit src/auth/**. Report only; do not edit or commit." &
agy --model gemini-pro-agent --print-timeout 20m --add-dir ~/src/github.com/acme/web/main \
  -p "Read the whole repo; map every call site of useSession(). Report only." > "$scratch/agy.md" &
pi -p --model zai/glm-5.2 --no-session \
  "In ~/src/github.com/acme/docs/main, list every dead link under docs/. Report only." > "$scratch/pi.md" &

wait                       # then JOIN: read all three, reconcile, and decide yourself
```

`wait` returns 0 only if every job did; check each file is non-empty. **SHOULD**
raise `agy --print-timeout` (**default 5m0s**) for any long delegation — it cuts
the run off otherwise. A delegation that outlives your patience belongs in the
background, polled — never left blocking the session.
