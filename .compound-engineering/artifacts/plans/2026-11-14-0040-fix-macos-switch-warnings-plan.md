---
title: "Remove the Causes of Three macOS Switch Warnings - Plan"
type: fix
date: 2026-11-14
topic: macos-switch-warnings
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Remove the Causes of Three macOS Switch Warnings - Plan

## Goal Capsule

- **Objective:** A production switch on the macOS host prints none of the three warnings it prints today, because the condition behind each one is gone.
- **Means:** The Antigravity CLI gets a plugin tree without the files it never loads and skips an unchanged install (KTD1, KTD2); root's `nix-env` runs with root's home (KTD3); `brew services` runs without the sudo marker when the user's GUI domain exists (KTD4).
- **Authority:** The Product Contract below, then the repository safeguards in `AGENTS.md`, then the Planning Contract.
- **Execution profile:** Four units in one PR. The implementer builds and verifies in the repository; the owner runs the production switch and reads its log.
- **Stop conditions:** Stop if a fix would need an agent to run `darwin-rebuild switch` or `nr switch`, to stop or restart the `container` API, or to change launchd state on the host.
- **Open blockers:** None.

---

## Product Contract

### Summary

Three warnings appear on every `nr switch` on the macOS host.
This work removes what causes each one and leaves the rest of the switch output as it is.

### Problem Frame

The switch succeeds, but its log carries warnings on every run, so a new warning is hard to tell from the standing ones.

1. `agy plugin validate` warns that `AGENTS.md` and `GEMINI.md` are never loaded, because the whole pinned Compound Engineering repository is handed to the Antigravity CLI as the plugin. The CLI then reinstalls the plugin ("replaced existing installation") on every Home Manager activation, whether or not the pin changed.
2. Nix warns `$HOME ('/Users/<user>') is not owned by you, falling back to the one defined in the 'passwd' file ('/var/root')`, because `scripts/nr-darwin` runs `nix-env` as root with the invoking user's `HOME`.
3. Homebrew warns `running through sudo, using user/* instead of gui/* domain!` and prints two hint lines, because `modules/darwin/container.nix` reaches `scripts/macos-container.sh` through `sudo --user`, and Homebrew reads `SUDO_USER`. On this host the login service `sh.brew.container` is loaded in `user/502` and absent from `gui/502`.

### Key Decisions

- KD1. Scope is the three warnings above. Governs R1 through R7. (session-settled: user-directed — chosen over also cleaning up repeated output that is not a warning, namely Pi's "Installing…" lines, the gpg version banner, and Homebrew's analytics and New Casks notices: the owner selected the three warning groups and left that group unselected.)
- KD2. Each warning is removed at its cause, and successful output stays visible. Governs R1, R4, R5, R6. (session-settled: user-approved — chosen over setting `HOMEBREW_SERVICES_NO_DOMAIN_WARNING` or `HOMEBREW_NO_ENV_HINTS` or discarding the Antigravity CLI's success output: hiding would leave the container login service in the wrong launchd domain, and output cleanup was declined in KD1.)
- KD3. The "no logo" note from `agy plugin validate` stays. Governs R2. (session-settled: user-approved — chosen over adding a logo to the pinned plugin: the manifest belongs to the upstream plugin.)

### Requirements

**Antigravity plugin**

- R1. `agy plugin validate` on the tree this repository installs reports no "never loaded" warning, and the installed plugin still provides every skill of the pinned plugin.
- R2. The validate, install, and enable output of a run that does install stays visible, including the "no logo" note.
- R3. An activation whose plugin tree is the one already installed runs neither `agy plugin validate` nor `agy plugin install` for that plugin. A changed tree, a missing installation, or a failed earlier install leads to a full validate and install.

**Root's nix-env**

- R4. `nr switch` on macOS registers the system profile without the `$HOME … is not owned by you` warning.

**Container login service**

- R5. When the user's GUI launchd domain exists, the container step's `brew services` calls print no domain warning and no hint lines, and a login service they register lands in `gui/<uid>`.
- R6. When the user's GUI launchd domain does not exist, such as a switch over SSH with nobody logged in at the console, the container step behaves as it does today.
- R7. The container step never stops or restarts a running `container` API, as today.

### Scope Boundaries

- No change to Pi's install output, the gpg banner, or Homebrew's analytics and New Casks notices (KD1).
- No change to the pinned plugin's manifest (KD3).
- No change to which skills Antigravity lists, or to the plugin skills directory the rebuilt ACP runtime reads.
- No live `darwin-rebuild switch` or `nr switch` by an agent; the owner runs the switch.
- Considered and not built: moving the existing `user/502` registration of `sh.brew.container` into `gui/502` during a switch. Moving it means `launchctl bootout` and a new bootstrap, which re-runs `container system start` against a shared runtime. The job is a one-shot that already ran, launchd loads the same plist into `gui/<uid>` at the owner's next login, and the `user/*` entry does not survive a reboot. Evidence that would change this: the service still missing from `gui/<uid>` after a login.
- Considered and not built: an allowlist tree holding only `plugin.json`, `skills`, and `assets`. Withholding the two root files gives the same validate result and cannot drop a `rules/`, `hooks/`, or MCP file that a later plugin version or a second plugin ships.

### Dependencies / Assumptions

- `agy plugin validate` on the pinned tree without root `AGENTS.md` and `GEMINI.md` reports 38 skills, zero warnings, and the logo note. Verified during planning with the installed `agy` against a scratch tree.
- `SUDO_USER` alone triggers Homebrew's `user/*` choice: `SUDO_USER=x brew services info container --json` reproduces the warning on this host and the same command without it does not. `bin/brew` passes `SUDO_USER` through, and `Library/Homebrew/services/system.rb` picks `user/<uid>` when `HOMEBREW_SUDO_USER` is set and `gui/<uid>` otherwise.
- `brew services info` finds a service in either domain, so an existing `user/*` registration still reports `registered: true` after the change and no second registration is attempted.
- `sudo -H` sets `HOME` to the target user's home on macOS, which is what Nix falls back to today.
- Repository checks prove the commands the steps run, not the text a real switch prints; that evidence comes from the owner's next switch.

### Sources / Research

- `home/h82/agents/agent-plugins.nix`: `sources`, the per-harness `exclude` field, `treeFor`, and the `nativeAgentPlugins` activation entry.
- `home/h82/agents/plugin-skills.nix`: `agyInstall`, the validate, install, and enable commands per plugin.
- `tests/antigravity-skills.nix` and `tests/native-plugins.py`: run the real activation text against recording `agy` and `grok` stubs.
- `scripts/grok-plugins`: precedent for skipping a native install when the registered source is the pinned one.
- `scripts/nr-darwin` and `tests/nr-darwin.sh`: the switch sequence and its recorded `sudo` argv.
- `modules/darwin/container.nix`, `scripts/macos-container.sh`, `tests/test_darwin_provisioning.py` (`test_container_states`, `test_activation_calls`).
- The nix-darwin activation script of this host: it reaches user commands with `launchctl asuser "$(id -u -- <user>)" sudo --user=<user> --`.
- `.compound-engineering/artifacts/solutions/best-practices/home-manager-activation-does-not-run-on-every-rebuild.md`: on macOS, Home Manager activation runs on every apply.
- `.compound-engineering/artifacts/solutions/best-practices/activation-step-grep-check-passes-an-echo-only-step.md` and `help-text-check-passes-while-cli-routes-to-wrong-host.md`: checks for these steps must execute them, not grep them.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The Antigravity CLI installs from a tree built with the existing `exclude` mechanism, with root `AGENTS.md` and `GEMINI.md` withheld for an `antigravity` harness key.** Implements R1, R2. `agent-plugins.nix` already prunes per harness through `treeFor`; `agyInstall` receives the pruned tree instead of `spec.src`. The plugin skills directory keeps pointing at the pinned source, so `tests/antigravity-skills.nix`'s link assertions stand.
- KTD2. **The installed tree's store path, written to a per-plugin record under the user's state directory after a successful install, decides whether to install.** Implements R3. The step skips validate and install only when the record equals the tree path and the plugin's directory under `~/.gemini/config/plugins/` still holds its manifest. The record is written after install exits zero, so a failed install is retried. `agy plugin enable` runs on every activation: it is cheap and reasserts the enabled state. The version string is not the key, because the tree can change while the version stays.
- KTD3. **`nr-darwin` passes `-H` to the `sudo` that runs `nix-env`.** Implements R4. The `sudo` that runs `activate` is unchanged: the warning comes from `nix-env`, and nix-darwin's activation manages its own user context.
- KTD4. **`macos-container.sh` runs its `brew services` calls without `SUDO_USER` when `gui/<uid>` exists, and unchanged otherwise.** Implements R5, R6, R7. The script tests the domain with `launchctl print gui/<uid>` once and builds its `brew` invocation from the result. The decision sits in the script, not in `container.nix`, so `test_container_states` can drive both branches with a `launchctl` stub.
- KTD5. **`container.nix` reaches the script through `launchctl asuser <uid> sudo --user=<user> --set-home`, the form nix-darwin's own user steps use.** Implements R5. A bootstrap into `gui/<uid>` then starts from the user's launchd context instead of root's.

### Assumptions

- `launchctl print gui/<uid>` exits non-zero when the domain does not exist and zero when it does, from a process running as that user.
- `agy plugin install` on a store tree that is a real copy behaves as it does on the pinned source; `treeFor` builds a copy with `cp -r`.
- A bootstrap into `gui/<uid>` succeeds from a `launchctl asuser` context during activation. The owner's switch log shows this only on a host where the service is not yet registered; on this host it is already registered and the branch does not run.

### Sequencing

U1, U2, and U3 are independent. U4 documents the result.

---

## Implementation Units

### U1. Antigravity plugin tree and install record

- **Goal:** The Antigravity CLI installs a tree it has no warning about, and installs it once per tree.
- **Requirements:** R1, R2, R3; KD2, KD3; KTD1, KTD2.
- **Dependencies:** None.
- **Files:** `home/h82/agents/agent-plugins.nix`, `home/h82/agents/plugin-skills.nix`, `tests/native-plugins.py`, `tests/antigravity-skills.nix`.
- **Approach:**
  1. Add the `antigravity` exclusions to the `compound-engineering` source and pass each plugin's tree, not its `src`, into `agyInstall`. Keep `agyInstall` usable with a plain source set, as the test's second plugin uses it.
  2. Keep the membership and `divergentExclusions` logic for the CLI-synchronized harnesses as it is; Antigravity is not a membership row.
  3. Wrap validate and install in the record comparison of KTD2. Print one line when an install is skipped, so the log says why nothing ran.
  4. The record lives under `~/.local/state/nix-config/`, beside the Xcode skills state.
- **Patterns to follow:** `treeFor` in `agent-plugins.nix`; the skip logic in `scripts/grok-plugins`; the stub and call-log shape in `tests/native-plugins.py`.
- **Execution note:** Extend `tests/native-plugins.py` first and watch each new scenario fail. The stub must create the installed plugin directory on `plugin install`, or the second-run scenario cannot tell a skip from a reinstall. Read the mutation-testing learnings `AGENTS.md` lists under "Before adding a repository check" before trusting the check.
- **Test scenarios:**
  - First activation in an empty home: `agy` receives validate, install, and enable for each plugin, with the pruned tree path as the validate and install argument.
  - The tree the check passes for `compound-engineering` holds `plugin.json` and every skill directory of the pinned source, and holds neither root `AGENTS.md` nor root `GEMINI.md`.
  - Second activation in the same home with the same tree: `agy` receives only enable, and the skip line is printed.
  - Second activation with a different tree path for the same plugin: validate, install, and enable run again and the record holds the new path.
  - Record present but the installed plugin directory removed: validate, install, and enable run.
  - `agy plugin install` exits non-zero: the activation text exits non-zero and no record is written, so the next run installs.
  - A second plugin added to the source set installs through the same function without Antigravity-specific code, as today.
  - `DRY_RUN` set: no `agy` call and no record.
- **Verification:** The `antigravity-skills` check passes with the new scenarios, and each scenario fails when the behavior it covers is removed.

### U2. Root home for the profile registration

- **Goal:** `nix-env` under `sudo` no longer sees the invoking user's `HOME`.
- **Requirements:** R4; KTD3.
- **Dependencies:** None.
- **Files:** `scripts/nr-darwin`, `tests/nr-darwin.sh`.
- **Approach:** Add `-H` to the one `sudo` call that runs `nix-env`. Update the test's `sudo` stub to accept the flag and the expected sequences to carry it.
- **Patterns to follow:** The existing sequence assertions in `tests/nr-darwin.sh`.
- **Test scenarios:**
  - `switch`: the recorded sequence shows `sudo -H -- <nix-env> -p <profile> --set <system>` followed by `sudo -- <system>/activate` without `-H`.
  - `switch --bootstrap` and any other path that registers the profile: same `-H` on the `nix-env` call.
  - `build`: no `sudo` call, as today.
- **Verification:** `tests/nr-darwin.sh` passes, and fails when `-H` is dropped from the script.

### U3. Container login service in the GUI domain

- **Goal:** `brew services` chooses `gui/<uid>` when that domain exists, with no warning, and keeps today's behavior when it does not.
- **Requirements:** R5, R6, R7; KD2; KTD4, KTD5.
- **Dependencies:** None.
- **Files:** `scripts/macos-container.sh`, `modules/darwin/container.nix`, `tests/test_darwin_provisioning.py`.
- **Approach:**
  1. In the script, decide once whether `gui/<uid>` exists and route both `brew services` calls through one helper that drops `SUDO_USER` in that case.
  2. In `container.nix`, prefix the command with `launchctl asuser` and the user's uid, keeping `--set-home`, the explicit `PATH`, and `lib.mkBefore`. `launchctl` must be reachable by absolute path, like `/usr/bin/sudo`.
  3. Leave the runtime and kernel logic untouched.
  4. `test_activation_calls` rewrites the activation line with regular expressions; adjust it so the `launchctl asuser` prefix is stubbed and the script is still called exactly once.
- **Patterns to follow:** The `launchctl asuser "$(id -u -- <user>)" sudo --user=<user> --` lines in nix-darwin's activation script; the stub style of `test_container_states`.
- **Execution note:** The `brew` stub should record whether `SUDO_USER` was set in its environment for each call. Asserting the script text would pass for a script that only mentions the variable. Read `.compound-engineering/artifacts/solutions/logic-errors/env-assignment-prefix-on-cd-never-reaches-the-next-command.md` before writing the stubbed environment.
- **Test scenarios:**
  - `launchctl print gui/<uid>` stub exits zero, `SUDO_USER` set on entry, service not registered: both `brew services info` calls and `brew services start` run with `SUDO_USER` unset, and the script exits zero.
  - Same with the service already registered: `brew services info` runs with `SUDO_USER` unset and `brew services start` is not called.
  - `launchctl print gui/<uid>` stub exits non-zero, `SUDO_USER` set on entry: every `brew` call still sees `SUDO_USER`, and the call sequence matches today's.
  - Runtime already running in each of the above: no `container system start` and no kernel call, as the existing second-run assertion checks.
  - The rendered activation line of every Darwin output runs the container script once, through the `launchctl asuser` prefix.
- **Verification:** `darwin-config` and `darwin-provisioning` pass on the macOS builder, and the new scenarios fail when the script stops dropping `SUDO_USER` or drops it unconditionally.

### U4. Documentation

- **Goal:** The documents that describe these steps match them.
- **Requirements:** R3, R5, R6.
- **Dependencies:** U1, U3.
- **Files:** `docs/macos.md`, `AGENTS.md`.
- **Approach:**
  1. In the container section of `docs/macos.md`, state which launchd domain the login service registers in and the SSH-without-console case.
  2. In `AGENTS.md`, adjust the sentence that says the Antigravity CLI validate, install, and enable run once per pinned plugin, so it covers the withheld files and the skipped install.
  3. `AGENTS.md` is an input of the `agent-instructions` check; run that check after the edit.
- **Test expectation:** none -- documentation only; the `agent-instructions` check guards the `AGENTS.md` input.
- **Verification:** `markdownlint-cli2` passes on both files and the `agent-instructions` check input still evaluates.

---

## Verification Contract

| Check | Command | Proves | Where |
| --- | --- | --- | --- |
| Antigravity install | `checks.x86_64-linux.antigravity-skills`; locally, `python3 tests/native-plugins.py` against the rendered activation text | U1 scenarios | CI `hosts` shard (`host-checks`), which runs only under the `full-ci` label; macOS builder for the local run |
| nr-darwin sequence | `tests/nr-darwin.sh` through the check that owns it in `tests/non-nixos-scripts.nix` | U2 scenarios | CI light shard (`checks.x86_64-linux.nr-darwin`); run the script directly on the macOS builder |
| Container step | `nix build --no-link .#checks.aarch64-darwin.darwin-provisioning` and `.#checks.aarch64-darwin.darwin-config` | U3 scenarios | macOS builder |
| Darwin outputs | `nix build --no-link .#checks.aarch64-darwin.darwin-outputs` | no regression in rendered activation | macOS builder |
| Instruction inputs | `checks.x86_64-linux.agent-instructions` | U4 keeps the check inputs valid | CI `hosts` shard (`host-checks`), which runs only under the `full-ci` label |
| Linux-only inputs from macOS | `nix derivation show` on the `x86_64-linux` checks above | their text inputs evaluate with the change | macOS builder |
| Declared macOS checks | `nix flake check` | `checks.aarch64-darwin` has no regression | macOS builder |
| Text hygiene | `git diff --check` and `markdownlint-cli2` on changed Markdown | formatting | local |
| Formatting | `nix fmt -- --ci` | Nix layout | CI `fmt` job; `formatter.aarch64-darwin` is absent |
| Closure jobs | `host-checks`, `vm-checks`, `build`, `build-darwin` under the `full-ci` label | every production and bootstrap output | CI |
| Mac evidence | the owner runs `nr switch` twice and reads the log: no `$HOME` warning, no Homebrew domain warning or hints, no "never loaded" warning, and no Antigravity install on the second run | R1, R3, R4, R5 | owner, reported separately |

Follow `.compound-engineering/artifacts/solutions/best-practices/verify-linux-only-nix-check-inputs-on-macos-through-derivation-show.md` for the `nix derivation show` row. A Linux check that has not run is deferred to CI, never passed.

## Definition of Done

- U1 through U4 are implemented and their verification outcomes hold.
- Every row of the Verification Contract that a macOS builder can run has passed locally; rows deferred to CI or to the owner are reported as deferred, not passed.
- No agent ran a switch, changed launchd state, or touched the running `container` API.
- No abandoned experiment, unused option, or test-only production seam remains in the diff.
- The PR body lists what was verified locally, what waits on CI, and the Mac evidence the owner still has to collect.
