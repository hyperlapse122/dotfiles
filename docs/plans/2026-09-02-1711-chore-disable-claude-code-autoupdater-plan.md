---
title: Disable the Claude Code Auto-Updater - Plan
type: chore
date: 2026-09-02
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/335
---

# Disable the Claude Code Auto-Updater - Plan

## Goal Capsule

- **Objective:** Every Claude Code build that lands on a host this repository provisions is one the repository chose. No unrecorded build is fetched onto the machine, and nothing invites an operator to move a host off the recorded build by hand.
- **Means:** Turn the background updater off through two declarations that agree on one value — the Linux session environment and Claude Code's own settings file (KTD1).
- **Authority:** Requirements R1-R7 own product behavior. KTD1-KTD4 own mechanism. Unit bodies override neither.
- **Execution profile:** Configuration and declaration work. The proof is a render gate, one added CI assertion, and an apply-and-observe check of the tool's own updater status.
- **Stop conditions:** Stop and report if the render-time validator in `.chezmoitemplates/claude-settings-validate.tmpl` rejects the new declared path, or if `chezmoi apply` reports a reconciler failure that the declaration caused.
- **Tail ownership:** `lfg` owns commit, push, PR, and CI watch.

---

## Product Contract

### Summary

Set `DISABLE_AUTOUPDATER=1` in two places that agree: `dot_config/environment.d/60-development.conf` for the Linux user session, and `agents.claude.settings` in `.chezmoidata/agents.yaml` so the Claude Code settings reconciler asserts `env.DISABLE_AUTOUPDATER` into `~/.claude/settings.json` on Linux and macOS alike. Add one CI assertion that the leaf reaches the settings file as a string. Record the ownership boundary in `AGENTS.md` so the next reader knows that a Claude Code version bump belongs in `.chezmoidata/releases.json` and nowhere else.

### Problem Frame

The Claude Code binary is a pinned vendor artifact. `.chezmoiexternals/ai-agents.toml` downloads it under a `sha256` and `size` checksum resolved from `.chezmoidata/releases.json`, and `packages/command-reconcile` promotes it into the versioned store at `~/.local/lib/commands/store/claude/<version>/claude`. Nothing in the repository sets `DISABLE_AUTOUPDATER`, so the running process still checks for and downloads newer builds on its own schedule.

The updater does not overwrite the pinned binary. It installs into its own tree at `$XDG_DATA_HOME/claude/versions` and repoints only a launcher it created itself; the shipped build states it "will not overwrite a launcher it does not own." Here `~/.local/bin/claude` is a `command-reconcile` symlink into the versioned store, so the pin holds — the store binary still hashes to the `704f1334…` the lock records. What the updater does instead is fetch a full ~205 MB build into `~/.local/share/claude/versions/` that nothing on the host will ever execute, and then report the running build as behind and propose `claude update`. That proposal is the path off the pin: it is a hand-move with no commit behind it, and the repository has no way to notice it happened.

So the cost is bandwidth and disk spent on builds the repository did not choose, plus a standing invitation to move a host off the recorded build. The pin is not broken today; it is unguarded. Claude Code is also the outlier here. Every other vendored tool moves only through a manifest bump, and unattended update and telemetry checks are already opted out through `dot_config/environment.d/` — `DOTNET_CLI_TELEMETRY_OPTOUT`, `TURBO_TELEMETRY_DISABLED`, `CODEGRAPH_TELEMETRY`, `POWERSHELL_UPDATECHECK_OPTOUT`.

### Key Decisions

- **Set the variable through both the session environment and Claude Code's settings file, not one of them.** Governs R1, R2. The environment entry is what the origin issue proposed and matches the sibling opt-outs; the settings entry is the only one that reaches macOS and the only one that survives a session started outside the systemd user manager.
- **Close the macOS gap in this change rather than deferring it to a linked issue.** Governs R2. The origin issue left this open. The settings reconciler already runs on darwin, so covering macOS costs one declared leaf and no new mechanism.
- **Disable the background updater only; leave a deliberate `claude update` reachable.** Governs R7. `DISABLE_UPDATES` would close the manual path too, but a maintainer sometimes needs to test an upstream build before bumping the lock. The audited path stays open; only the unattended one closes.

### Requirements

**Environment pin**

- R1. `DISABLE_AUTOUPDATER=1` is present in the Linux user session environment and survives `chezmoi apply`.
- R2. A Claude Code session sees `DISABLE_AUTOUPDATER=1` on Linux and on macOS, independent of the session environment.
- R3. Both declarations carry the same value, the string `1`.
- R7. A deliberate `claude update` remains available; only the background updater is off.

**Provenance**

- R4. Each declaration states why it exists and where a Claude Code version bump belongs.
- R5. `AGENTS.md` records that the Claude Code binary has one owner — the release lock — and that the background updater is pinned off in two places.

**Non-regression**

- R6. The new settings leaf leaves every key another writer owns in `~/.claude/settings.json` untouched, reaches the file as a JSON string, and the render-time declaration guard accepts it.

### Scope Boundaries

- The `dot_config/environment.d/` directory stays Linux-only. `dot_config/.chezmoiignore:5` drops it on other hosts, and this change does not alter that.
- The pinned version in `.chezmoidata/releases.json` is not bumped here.
- No new CI job. `.ci/test-claude-settings-reconcile.sh` already reads the declaration from `agents.yaml`, so the new leaf enters its existing assertions unchanged; this plan adds exactly one assertion to that suite, for the leaf's JSON type (see U2).

#### Deferred to Follow-Up Work

- Pruning `~/.local/share/claude/versions/`. Builds already downloaded before this change stay on disk, and the tool's own cleanup is throttled and lock-guarded rather than guaranteed. Reclaiming that space is a separate housekeeping item.
- A guard asserting that the two `DISABLE_AUTOUPDATER` declarations hold the same value. Low drift risk against the cost of a new gate.
- A drift check that re-hashes the store binary against the locked `sha256`. The completion-marker short-circuit in `packages/command-reconcile/src/producer.ts` means the reconciler would not repair a rewritten store generation. Nothing observed rewrites one today, so this is a reconciler-integrity concern wider than one tool.

### Sources

- Origin issue: https://github.com/hyperlapse122/dotfiles/issues/335
- `.chezmoiexternals/ai-agents.toml` — the `[claude]` external and its `sha256`/`size` checksum block.
- `.chezmoidata/releases.json` — the `vendorManifest` entry pinning version `2.1.258` with per-artifact digests.
- `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` — the leaf-assertion reconciler, gated on `ne .chezmoi.os "windows"`, so it runs on darwin.
- `.chezmoitemplates/claude-settings-validate.tmpl` — the render-time path grammar `^[A-Za-z][A-Za-z0-9_-]*([.][A-Za-z][A-Za-z0-9_-]*)*$`, the leaf-only rule, the overlap rule, and the `hooks`/`enabledPlugins`/`extraKnownMarketplaces` denial list.
- `.ci/test-claude-settings-reconcile.sh` — `assert_declared_present` compares the live value against the same declaration rendered from `agents.yaml`, so it cannot distinguish a string from a number on its own.
- `.github/workflows/refresh-release-lock.yml` — hourly `cron: "0 * * * *"`; the pin tracks upstream without the updater.
- `.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl` and `.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl` — `jq` is a stage-20 base package on both platforms, long before the stage-70 reconciler.
- The shipped binary at `~/.local/lib/commands/current/claude/claude`: it reads `process.env.DISABLE_AUTOUPDATER`, documents the `env` block of `~/.claude/settings.json` as a supported carrier, states that the variable "turns off BACKGROUND auto-updates only," reports the reason string `set by env: DISABLE_AUTOUPDATER`, and refuses to "overwrite a launcher it does not own."
- Observed on this host: `~/.local/share/claude/versions/2.1.258` (215473560 bytes) written four minutes after the chezmoi install, while `~/.local/lib/commands/store/claude/2.1.258/claude` still hashes to the locked digest.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Two declarations, one value.** `dot_config/environment.d/60-development.conf` carries the Linux session floor; `agents.claude.settings` carries the tool-level pin that reaches macOS. Per R3 both hold the string `1`. The settings reconciler asserts nothing and exits 0 when `~/.claude/settings.json` is unreadable, when an ancestor of the declared path holds a scalar or array, or when another writer changes the file while the apply stages its replacement. The session variable still holds on Linux in all three states, which is what the second declaration buys.
- KTD2. **Declare `env.DISABLE_AUTOUPDATER` as a settings leaf rather than adding a new writer.** The reconciler in `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` already asserts declared leaves into `~/.claude/settings.json` on every apply and preserves siblings. `env` is not in the validator's denial list, so the existing mechanism carries the value with no new script.
- KTD3. **Write the value as the YAML string `"1"`, and assert that in CI.** Claude Code's `env` block holds string values, and the render-time guard rejects only containers, so an unquoted `1` would render as a number and reach the file as a JSON number. The existing reconciler suite compares the live value against the same rendered declaration, so it would pass on both sides; one type assertion is what makes KTD3 enforceable.
- KTD4. **Do not touch `.chezmoidata/releases.json` or `packages/release-lock`.** The lock is machine-generated and the pinned version is correct; this change protects the pin rather than moving it.

### Assumptions

- Setting `DISABLE_AUTOUPDATER` through the settings `env` block reaches the updater check. The shipped binary names the `env` block of `~/.claude/settings.json` as a supported carrier for exactly this variable, and its own legacy migration writes that key there. A later pinned build could drop the key from its allowlist without anything in the repository noticing; the updater-status gate in the Verification Contract is what would catch that.
- Declaring `env.DISABLE_AUTOUPDATER` does not contend with another writer. Claude Code writes that key only during the one-time legacy `autoUpdates` migration, and it writes the same value, so a write from either side converges.
- No host in this fleet depends on Claude Code updating itself between manifest bumps. `.github/workflows/refresh-release-lock.yml` re-resolves the lock from upstream hourly and commits the result, so the pin moves on its own schedule; only the unaudited path closes.

### Sequencing

U1 and U2 are independent and may land in either order. U3 records what both did, so it comes last.

---

## Implementation Units

### U1. Set the variable in the Linux session environment

- **Goal:** `DISABLE_AUTOUPDATER=1` reaches the Linux user session through `environment.d`, next to the other agent-tool entries.
- **Requirements:** R1, R3, R4
- **Dependencies:** none
- **Files:** `dot_config/environment.d/60-development.conf`
- **Approach:**
  1. Add a `# Claude Code` block after the `# codegraph` entry and before `# agent-browser`, keeping the file's one-comment-per-tool shape.
  2. Set `DISABLE_AUTOUPDATER=1`.
  3. State in the comment that the binary is pinned in `.chezmoidata/releases.json` and that a version bump belongs there.
- **Patterns to follow:** the existing `DOTNET_CLI_TELEMETRY_OPTOUT`, `TURBO_TELEMETRY_DISABLED`, and `CODEGRAPH_TELEMETRY` entries in the same file — a bare `NAME=value` under a tool-name comment, no `export`.
- **Test scenarios:** Test expectation: none -- this is a static chezmoi target with no rendering logic and no CI gate over `environment.d` content. Coverage is the apply-and-observe check in the Verification Contract.
- **Verification:** The rendered target under `~/.config/environment.d/60-development.conf` carries the line, and `systemctl --user show-environment` reports the variable after `systemctl --user daemon-reload` re-runs the environment generators, or after a fresh login.

### U2. Declare the settings leaf so macOS is covered

- **Goal:** The Claude Code settings reconciler asserts `env.DISABLE_AUTOUPDATER` into `~/.claude/settings.json` on every apply, on Linux and macOS, as a JSON string.
- **Requirements:** R2, R3, R4, R6
- **Dependencies:** none
- **Files:** `.chezmoidata/agents.yaml`, `.ci/test-claude-settings-reconcile.sh`
- **Approach:**
  1. Add `env.DISABLE_AUTOUPDATER: "1"` to `agents.claude.settings`, quoted per KTD3.
  2. Extend the block comment above the declaration to say that this leaf is what covers a macOS host, where `dot_config/environment.d/` is not deployed, and that a Claude Code version bump belongs in `.chezmoidata/releases.json` — matching U1 step 3.
  3. Add one type assertion to the reconciler suite's absent-file case, checking that the written leaf is a JSON string rather than a number.
- **Patterns to follow:** the sibling declared paths in the same map, especially the dotted `modelSettings.claude-opus-5.effortLevel` leaf, and the comment style already used for the `hooks` / `enabledPlugins` ownership note. For the assertion, mirror the suite's existing `jq -e` checks and its `fail` helper.
- **Test scenarios:**
  - `chezmoi execute-template` over the declaration renders without failing: the path passes the grammar rule, is not a container, does not overlap a sibling path, and does not address `hooks`, `enabledPlugins`, or `extraKnownMarketplaces`.
  - The suite still passes against a settings fixture that already holds other writers' keys — the run asserts every declared leaf, including the new one, and leaves `hooks`, `enabledPlugins`, and `extraKnownMarketplaces` unchanged.
  - The absent-file case produces a settings file whose `env.DISABLE_AUTOUPDATER` has JSON type `string`; the new assertion fails when the declaration is unquoted.
  - A converged re-run over a fixture that already holds the leaf writes nothing, so a second apply changes zero bytes.
- **Verification:** `.ci/test-claude-settings-reconcile.sh` passes against the rendered reconciler, including the new type assertion, and the render gate reports no validator failure.

### U3. Record the ownership boundary in AGENTS.md

- **Goal:** A reader of the repository instructions learns that the Claude Code binary has one owner and that the background updater is pinned off in two places.
- **Requirements:** R5
- **Dependencies:** U1, U2
- **Files:** `AGENTS.md`
- **Approach:**
  1. Add the note to the release-lock paragraph that already describes `vendorManifest` entries and the hand-edit prohibition.
  2. Name both declaration sites and state that a Claude Code version moves only through a `.chezmoidata/releases.json` bump.
  3. Keep it to one or two sentences; the reasoning lives in the two declarations' own comments.
- **Patterns to follow:** the existing `dot_config/tmux/tmux.conf` paragraph in `AGENTS.md`, which names a paired configuration, says why the pair exists, and names its verification.
- **Test scenarios:** Test expectation: none -- documentation with no gate over its content.
- **Verification:** The paragraph names both files and the release lock, and does not restate the mechanism the declarations' own comments own.

---

## Verification Contract

The `Proves` column names a unit when the gate checks that unit's artifact, and a requirement when it observes behavior no single unit owns.

| Gate | Command | Proves | Done signal |
|---|---|---|---|
| Render | `chezmoi execute-template` over the reconciler template, as CI's agent-reconciliation job does | U2 | Renders with no `config-claude-settings:` failure |
| Reconciler suite | `.ci/test-claude-settings-reconcile.sh <rendered-script>` | U2 | Exits 0; every declared leaf asserted as the right JSON type, no other writer's key disturbed |
| Apply | `chezmoi apply` on a Linux host | U1, U2 | Exits 0; the reconciler reports asserted paths or converged silence |
| Observe — session | `systemctl --user show-environment`, after `systemctl --user daemon-reload` or a fresh login | R1 | `DISABLE_AUTOUPDATER=1` present |
| Observe — settings | Read `env.DISABLE_AUTOUPDATER` from `~/.claude/settings.json` | R2 | Holds the JSON string `"1"` |
| Observe — updater status | Claude Code's own update status (`claude doctor`) in a session started after the apply | R2, R7 | Reports the updater off with reason `set by env: DISABLE_AUTOUPDATER`, and still offers a manual update |

The `Observe — updater status` gate is the only one that falsifies the change: the pin's digest matches with the updater enabled too, so a hash check proves nothing here. Run it on a Linux host, and on a macOS host when one is available — macOS coverage is the whole reason U2 exists.

The CI surface for this change is the `agent reconciliation` job in `.github/workflows/ci.yml`, which renders the reconciler template and runs `.ci/test-claude-settings-reconcile.sh` against it.

---

## Definition of Done

**Global**

- `DISABLE_AUTOUPDATER=1` is declared in `dot_config/environment.d/60-development.conf` and as `env.DISABLE_AUTOUPDATER: "1"` under `agents.claude.settings`.
- Both declarations state why they exist and point a version bump at `.chezmoidata/releases.json`.
- `AGENTS.md` records the ownership boundary.
- Claude Code reports its updater off with reason `set by env: DISABLE_AUTOUPDATER` on at least a Linux host, and a deliberate update is still offered.
- CI is green, with `.ci/test-claude-settings-reconcile.sh` passing against the new declaration and its type assertion.
- No exploratory or abandoned edits remain in the diff — in particular, `.chezmoidata/releases.json` and `packages/release-lock` are untouched.

**Per unit**

- U1: the line is present in the target file under a `# Claude Code` comment.
- U2: the leaf renders, passes the declaration guard, reaches the settings file as a string, and the suite asserts that type.
- U3: the `AGENTS.md` note names both declaration sites and the release lock.
