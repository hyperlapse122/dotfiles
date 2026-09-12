---
title: 1Password Autostart Apply Conflict - Plan
type: fix
date: 2026-09-13
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# 1Password Autostart Apply Conflict - Plan

## Goal Capsule

- **Objective:** `chezmoi update --init` and `chezmoi apply` finish without the `.config/autostart/1password.desktop has changed since chezmoi last wrote it?` prompt, including on hosts that already received the old entry, and 1Password still starts at login on managed hosts.
- **Means:** seed the app's own autostart entry once with a `create_` target and stop managing the legacy entry without an apply-time removal (KTD1, KTD2).
- **Authority:** this plan, then `AGENTS.md`, then the user-scoped instructions.
- **Stop conditions:** stop when chezmoi v2.72.1 does not accept the `create_private_` source name, or when the stateful migration scenario in the Verification Contract prompts or exits non-zero.
- **Execution profile:** Lightweight. Configuration change with scratch-apply verification only; never apply to the live `$HOME`.
- **Tail ownership:** the calling pipeline owns commit, push, PR, and CI.

## Product Contract

### Summary

Replace the managed `dot_config/autostart/1password.desktop` with a seed-once entry that uses the file name 1Password itself writes. Stop managing the legacy entry, and document its one-time manual removal.

### Problem Frame

1Password 8.12.36 (rpm `1password-8.12.36-1.x86_64`) manages its own "start at login" file at `~/.config/autostart/com.onepassword.OnePassword.desktop`. Its `resources/app.asar` references only that name. The chezmoi-managed `~/.config/autostart/1password.desktop` changed after chezmoi wrote it, so the apply stopped at an overwrite prompt. On a headless apply that prompt fails with `could not open a new TTY`. A host that answers "overwrite" ends with two autostart entries for the same app.

On the observed host, the app-written file has mode 0600 and differs from the managed file only in `StartupWMClass=com.onepassword.OnePassword`. The process that changed the legacy file is not confirmed; see Assumptions.

A scratch probe with chezmoi v2.72.1 and persistent state showed that any chezmoi-driven removal of a changed target raises the same prompt and aborts the whole apply. This holds for a `.chezmoiremove` entry and for a `remove_` source attribute. Deleting the source alone applies cleanly and leaves the legacy file unmanaged.

### Requirements

**Apply behavior**

- R1. An apply does not prompt about any 1Password autostart file, on a fresh host and on a host whose deployed legacy entry changed after chezmoi wrote it.
- R2. An apply never overwrites an autostart entry that 1Password wrote.

**Login behavior**

- R3. A managed host that has no 1Password autostart entry receives one that starts `/opt/1Password/1password --silent`.
- R4. chezmoi manages exactly one 1Password autostart entry, and a legacy `1password.desktop` left on an already-deployed host has a documented one-time manual removal.

### Scope Boundaries

- The launcher `dot_local/share/applications/1password.desktop` and its `StartupWMClass=1Password` are not changed.
- The KDE window rule in `.chezmoidata/kde.yaml` that matches `wmclass 1password` is not changed.
- The Jetson installer entry written by `.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl` is not changed.

#### Deferred to Follow-Up Work

- Check whether the 8.12 window class change (`com.onepassword.OnePassword`) breaks the KDE `1password-auth-above` rule and the launcher `StartupWMClass`. This needs a live KDE session check and is outside the apply warning.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Seed the app's own file name with a `create_` target.** The source becomes `dot_config/autostart/create_private_com.onepassword.OnePassword.desktop`, with the content the app writes. chezmoi writes a `create_` target only when it is absent, so a later rewrite by the app is never a conflict (R1, R2), and a fresh host still gets autostart (R3). `private_` matches the app's 0600 mode; chezmoi still applies that mode to an existing file, which changes permissions only. Rejected: keep managing `1password.desktop` (the conflict repeats on every apply); stop managing autostart entirely, like `~/.claude.json` in `AGENTS.md` (a fresh host would not autostart until the user toggles the setting); a `modify_` script (more code for no behavior the seed does not give).
- KTD2. **Stop managing the legacy entry by deleting its source only, and document a one-time manual removal.** The scratch probe in the Problem Frame showed that a `.chezmoiremove` entry or a `remove_` attribute prompts and aborts the apply on any host whose legacy file changed, which breaks R1 on the hosts this fix exists for. Deleting the source applies cleanly there. The leftover file follows the `docs/decommission/` checklist convention that `AGENTS.md` allows for one-time manual reversals (R4). Rejected: `.chezmoiremove` (verified prompt and abort on changed targets); `remove_` attribute (same verified behavior); a teardown script (forbidden by `AGENTS.md`).

### Assumptions

- The app treats an existing `com.onepassword.OnePassword.desktop` with this content as its own entry. The observed file on this host has the same content.
- A leftover legacy entry launches the same single-instance app, so until the operator removes it, the second launch has no user-visible effect.
- The evidence comes from 1Password 8.12.36 on Fedora. The Jetson tarball is pinned to the same release lock. A later 1Password release that renames the autostart file again would need a new change; the stop condition does not detect that.
- When the user turns "start at login" off, the app deletes the file and the next apply seeds it again. This matches the repository's intent that 1Password autostarts.

---

## Implementation Units

### U1. Seed-once 1Password autostart entry

- **Goal:** Replace the managed legacy entry with the seed-once entry.
- **Requirements:** R1, R2, R3, R4; KTD1, KTD2.
- **Dependencies:** none.
- **Files:**
  - Delete `dot_config/autostart/1password.desktop`.
  - Create `dot_config/autostart/create_private_com.onepassword.OnePassword.desktop`.
- **Approach:**
  1. Move the file with git so history follows it.
  2. Set `StartupWMClass=com.onepassword.OnePassword`, and keep the other keys identical to the current source.
  3. Add no `.chezmoiremove` entry and no `remove_` source (KTD2).
- **Patterns to follow:** sibling entries in `dot_config/autostart/`; chezmoi `create_` and `private_` attributes described in `AGENTS.md` "Source layout and attributes".
- **Execution note:** This is configuration. Prove it with scratch applies, not unit tests.
- **Test scenarios:**
  - Scratch destination with no autostart files: apply. `com.onepassword.OnePassword.desktop` is created with mode 0600 and the planned content.
  - Scratch destination that already has `com.onepassword.OnePassword.desktop` with different content: apply. The file content is unchanged and no prompt appears.
  - Stateful migration: with one scratch `--persistent-state` file, apply the pre-change source, append a line to the deployed `1password.desktop`, then apply this branch's source with `--no-tty` and stdin not a TTY. The apply exits 0 without a prompt, the seeded entry exists, and the legacy file remains unchanged.
  - `chezmoi managed` for the scratch run lists `.config/autostart/com.onepassword.OnePassword.desktop` and no longer lists `.config/autostart/1password.desktop`.
- **Verification:** all four scenarios pass.

### U2. Document the legacy entry removal

- **Goal:** Give operators of already-deployed hosts one checked step to remove the unmanaged legacy entry.
- **Requirements:** R4; KTD2.
- **Dependencies:** U1.
- **Files:** Create `docs/decommission/1password-legacy-autostart.md`.
- **Approach:**
  1. Follow the label, "apply first", and numbered-checklist shape of `docs/decommission/figma-global-skills.md`.
  2. Tell the operator to apply the revised source first, confirm `~/.config/autostart/com.onepassword.OnePassword.desktop` exists, then delete `~/.config/autostart/1password.desktop`.
  3. State that chezmoi removes nothing, and why: a chezmoi removal of the changed file prompts and aborts the apply.
- **Patterns to follow:** `docs/decommission/figma-global-skills.md`.
- **Test expectation:** none -- operator documentation with no runtime behavior; checked by review and `git diff --check`.
- **Verification:** the checklist names both paths and the apply-first order.

---

## Verification Contract

Every check follows `AGENTS.md` "Verification": scratch directory under `$HOME/.cache/agent-scratch/`, stub `op`, empty config, `--source "$PWD"` for this branch, throwaway `--destination`, and `PATH="$scratch/bin:/usr/bin:/bin"` with an absolute `chezmoi` path. Limit applies to the autostart target with `--exclude scripts,externals,encrypted` so no script runs. The pre-change source for the migration scenario is a scratch copy of the current `dot_config/autostart/1password.desktop`, never the deployed source directory.

| Check | Proves |
|---|---|
| Scratch apply into an empty destination | R3 |
| Scratch apply over a pre-seeded app file, content compared before and after | R1, R2 |
| Stateful migration scenario from U1 exits 0 with `--no-tty` | R1 on already-deployed hosts |
| `chezmoi managed` lists only the new 1Password autostart entry | R4 |
| `git diff --check` and `git status` | clean, scoped diff |

## Definition of Done

- U1 and U2 are implemented and every Verification Contract check passes.
- The diff touches only `dot_config/autostart/`, `docs/decommission/1password-legacy-autostart.md`, and this plan.
- No live `$HOME` apply ran, and no experimental files remain in the diff.
