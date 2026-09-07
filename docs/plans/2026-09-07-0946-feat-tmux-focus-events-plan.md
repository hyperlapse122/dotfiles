---
title: tmux Focus Event Passthrough - Plan
type: feat
date: 2026-09-07
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# tmux Focus Event Passthrough - Plan

## Goal Capsule

- **Objective:** an application running inside a tmux pane — an agent TUI in an `aoe` session, an editor, a shell integration — learns when the outer terminal window gains or loses focus, instead of behaving as if the window were always focused.
- **Means:** set `focus-events on` in the managed tmux config, unguarded by a version test (KTD1, KTD2).
- **Authority:** the tmux manual for `focus-events`; the existing structure and comment contract of `dot_config/tmux/tmux.conf`; `AGENTS.md` for source-state editing and verification.
- **Execution profile:** one source-state edit to a static (non-template) chezmoi file. No `chezmoi apply` against the live `$HOME`. Verification runs against a scratch destination and a scratch tmux server.
- **Stop conditions:** stop and report if loading the edited config on the local tmux emits a config error, or if `focus-events` cannot be read back as `on` from a scratch server.
- **Tail ownership:** the invoking pipeline owns commit, push, PR, and the CI watch.

---

## Product Contract

### Summary

Add `set -g focus-events on` to `dot_config/tmux/tmux.conf`, in its own purpose section, and update the file's header comment so the setting count and purpose list stay true.

### Problem Frame

tmux ships `focus-events` as `off`. With it off, tmux never requests DEC mode 1004 focus reporting from the outer terminal and never forwards `FocusGained`/`FocusLost` to the programs in its panes. Those programs then cannot tell a focused window from a background one.

That gap lands on this machine's normal working shape. `agent-of-empires` attaches every session through tmux (`default_attach_mode = "tmux"` in `dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl`), so agent TUIs and editors run one layer below tmux, and the managed terminals — Ghostty and WezTerm — both report focus. The signal exists at both ends and only the tmux default stops it in the middle.

This is the same class of defect the file's `extended-keys` block already documents: an upstream tmux default that silently drops a capability the outer terminal and the inner application both support.

### Requirements

- **R1** — the deployed `~/.config/tmux/tmux.conf` sets `focus-events` to `on` globally, so tmux requests focus reporting from the outer terminal and passes focus events to pane applications.
- **R2** — the new setting carries a short comment that records the upstream default and why it is changed, matching how every other setting in the file is introduced.
- **R3** — the header comment's setting count and purpose list describe the file after the edit; no stale "Three settings, two purposes" claim survives.
- **R4** — the config loads with no tmux config error on the tmux available here (3.7c) and needs no version guard.

### Scope Boundaries

Out of scope: `terminal-features` entries, Ghostty or WezTerm config changes, `agent-of-empires` config changes, and any other tmux option. Nothing is deployed to the live `$HOME` by this plan.

### Sources

- `dot_config/tmux/tmux.conf` — the three existing settings and their comment contract.
- tmux manual, `focus-events`: "When enabled, focus events are requested from the terminal if supported and passed through to applications running in tmux."
- `tmux -V` here reports `3.7c`; `tmux show-options -g focus-events` reports `off` today.

---

## Planning Contract

### Key Technical Decisions

- **KTD1 — give the setting its own purpose section, and update the header.** The file is organized by purpose (`--- modified keys ---`, `--- terminal hyperlinks ---`) and its header counts the settings. Focus reporting is a third purpose, so it gets a third section rather than being appended to an existing one, and the header line is rewritten to match (governs R2, R3). Rejected: appending the line under `--- modified keys ---`, which would file a focus setting under a keyboard heading and leave the header wrong.
- **KTD2 — no `%if` version guard.** `focus-events` has existed since tmux 1.9; only `extended-keys-format` needed the `%if #{>=:#{version},3.5}` guard because it arrived in 3.5. Guarding an option that predates every supported tmux would add noise and a false claim of fragility (governs R4). Rejected: mirroring the neighboring guarded block for symmetry.
- **KTD3 — `set -g`, not `set -ag` or a per-session set.** The option is a boolean, not an appendable list like `terminal-features`, and it applies to every session (governs R1).

### Assumptions

- The outer terminal decides whether focus reporting actually happens; tmux only requests it. A terminal that does not support DEC 1004 ignores the request, so the setting is inert rather than harmful there.

---

## Implementation Units

### U1. Enable focus-events in the managed tmux config

- **Goal:** `dot_config/tmux/tmux.conf` sets `focus-events on` in its own purpose section, with an accurate header.
- **Requirements:** R1, R2, R3, R4.
- **Files:** `dot_config/tmux/tmux.conf`.
- **Approach:** rewrite the header comment's count-and-purpose sentence to cover three purposes and four settings (KTD1). Add a `# --- focus reporting ---` section after the hyperlinks section containing a short comment and `set -g focus-events on` (KTD1, KTD3). Write no version guard (KTD2). The comment states the upstream default and the consequence of leaving it, in the voice the file already uses; it does not restate what the option name already says.
- **Test scenarios:**
  - Happy path: start a scratch tmux server with only this file, then read the option back — it reports `focus-events on`.
  - Error path: re-sourcing the file on that running scratch server exits 0 and prints nothing.
  - Edge case: the file contains no `%if` block around the new setting, and the existing `extended-keys-format` guard is untouched.
  - Integration: applying the source state to a scratch chezmoi destination reproduces the edited file byte-for-byte, confirming the static (non-template) file deploys as written.
- **Verification:** the commands in the Verification Contract below.

---

## Verification Contract

Run from the worktree root. No command below touches the live `$HOME`.

```sh
# 1. tmux loads the config, reports no error, and reports the option as on.
# The pre-kill matters: tmux ignores -f when a server already listens on the
# socket, so a survivor from an earlier run would answer with its stale value.
tmux -L ce-focus-events kill-server 2>/dev/null || true
tmux -L ce-focus-events -f dot_config/tmux/tmux.conf new-session -d 'sleep 60'
tmux -L ce-focus-events source-file dot_config/tmux/tmux.conf  # expect: exit 0, no output
tmux -L ce-focus-events show-options -g focus-events           # expect: focus-events on
tmux -L ce-focus-events kill-server

# 2. The static file deploys unchanged into a scratch destination.
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/target/.config/tmux"
: > "$scratch/empty.toml"
chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" \
  apply "$scratch/target/.config/tmux/tmux.conf"
diff -u dot_config/tmux/tmux.conf "$scratch/target/.config/tmux/tmux.conf"

# 3. Repo hygiene.
git diff --check
git status --short
git diff -- dot_config/tmux/tmux.conf
```

Step 1 is the proof of R1 and R4. `source-file` against the running scratch server is what proves R4: a detached `new-session` queues config errors for a client that never attaches, so it exits 0 and prints nothing even on a malformed file, while `source-file` exits 1 with `invalid option: …` on stderr.

Step 2 is the proof that the deployed target matches the source for this static file. `chezmoi apply` on a named leaf target needs its parent directories to exist in the destination already, so the `mkdir -p` creates them. Against the empty scratch config chezmoi also prints `warning: config file template has changed, run chezmoi init to regenerate config file` on stderr; that warning is benign, does not change the exit status, and is not a failure.

Step 3 confirms the diff stays inside the requested scope, and its `git diff` output is where R2 and R3 are checked — both are comment-text requirements that no command can assert. No `.ci/` test covers `dot_config/tmux/`, so no existing gate needs updating.

---

## Definition of Done

- R1 and R4 hold, shown by step 1. R2 and R3 hold, read off step 3's diff.
- `tmux -L ce-focus-events source-file …` exited 0 with no output, `show-options -g focus-events` printed `focus-events on`, and the scratch server was killed.
- The diff touches `dot_config/tmux/tmux.conf` only, plus this plan file.
- No scratch server, socket, or experimental line is left behind: no abandoned `%if` guard, no commented-out alternative, no second copy of the setting.
