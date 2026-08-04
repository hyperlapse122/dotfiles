---
title: Converge mxm4-haptic On A Clean Host - Plan
type: fix
date: 2026-08-04
topic: mxm4-haptic-clean-state
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Converge mxm4-haptic On A Clean Host - Plan

## Goal Capsule

- **Objective:** Make the phase-60 mxm4-haptic provisioner converge on the first `chezmoi apply --init` of a freshly installed Fedora host, without a mise-activated shell and without `chezmoi state reset`.
- **Product authority:** Issue #158 reports the live bootstrap failure: `mxm4-haptic: preflight: vp is required`, then `Command /home/h82/.local/bin/mxm4-hapticd is not executable: No such file or directory` with `mxm4-haptic: unit validation: mxm4-hapticd.service is invalid`.
- **Execution profile:** Fix both defects in the POSIX provisioner, mirror the toolchain half on the Windows counterpart, and extend the deterministic fixtures so the reported failure reproduces without the fix.
- **Open blockers:** None.

---

## Product Contract

### Summary

A first apply on a host that has only just been provisioned must build, install, and start the haptic daemon by itself. Neither an activated shell nor a second apply may be a precondition.

### Problem Frame

Two independent defects made the first apply unrecoverable:

1. **Toolchain visibility.** `chezmoi apply` runs scripts with the invoking shell's PATH. On a fresh host that shell has never sourced `mise activate`, so `vp` (the global mise `viteplus` tool), `node`, and `cargo` (this repo's `mise.toml` rust pin) are absent even though `00-tools` already trusted the configs. `require_command vp` then failed the whole provisioner. The sibling phase-60 builders (`build-figma-auth`, `build-kimi-reconcile`) already run their commands through `mise exec` for exactly this reason; this provisioner did not.
2. **Startup-definition verification order.** Preflight ran `systemd-analyze --user verify` on the managed unit before the build. That command resolves `ExecStart=%h/.local/bin/mxm4-hapticd` against the filesystem, and on a first apply the binary does not exist yet — so verification rejected a perfectly valid unit before the install that would have satisfied it. Nothing in an apply could ever break the cycle, which is why the reporter's workaround needed an activated shell *and* `chezmoi state reset`.

### Requirements

- R1. With `vp`, `node`, and `cargo` reachable only through mise, the provisioner builds the plugin and the Rust binaries and converges.
- R2. With those commands already on PATH, the provisioner uses them directly and runs each from the directory the build expects.
- R3. A command that neither PATH nor mise can supply remains a fatal preflight failure that installs nothing and mutates no manager.
- R4. A first apply on a host with no installed daemon converges: the unit is verified after the binary is installed and before the first manager mutation.
- R5. A genuinely invalid unit remains fatal and still mutates no manager.
- R6. The plugin build populates `packages/node_modules` before bundling, because the member's Vite+ config imports vite-plus from the workspace.
- R7. The Windows counterpart resolves its toolchain by the same rule; its Task Scheduler registration is unaffected because it does not resolve the daemon path at registration time.
- R8. The fixtures reproduce issue #158 against the pre-fix provisioner and pass against the fixed one.

### Acceptance Examples

- AE1. **Covers R1.** Given a PATH without `vp`/`node`/`cargo` but with `mise`, when the provisioner runs, then each build command is invoked as `mise -C <pin directory> exec -- <command>` and both components install.
- AE2. **Covers R3.** Given neither `vp` nor `mise`, when the provisioner runs, then it fails with `preflight: vp is required (not on PATH and mise cannot provide it)` and no live file or manager is touched.
- AE3. **Covers R4, R8.** Given a bare managed home and a `systemd-analyze` that rejects a unit whose `ExecStart` does not exist, when the provisioner runs, then the daemon install precedes unit verification, verification precedes `daemon-reload`, and the run converges.
- AE4. **Covers R5.** Given a `systemd-analyze` that fails, when the provisioner runs, then it fails fatally after the install and before any `systemctl --user` mutation.

### Scope Boundaries

- Do not weaken the transaction: no manager mutation may precede a successful build, artifact validation, and startup-definition validation.
- Do not convert any fatal boundary in this provisioner into a soft skip.
- Do not change fingerprints, stamps, waveform data, unit contents, or the readiness/endpoint contract.
- Do not deploy the source state to the live home directory during verification.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Resolve per command, prefer the activated one.** `resolve_build_command` records whether a command needs mise; `run_build_command` then either runs it from the requested directory (`cd`) or as `mise -C <directory> exec -- …`, which changes directory itself. Chosen over prepending mise's bin paths to PATH (would require a repo-wide `mise install` with its postinstall hooks as a side effect) and over always going through mise (would ignore an activated toolchain and slow every apply).
- KTD2. **Do not probe the tool during preflight.** Preflight only requires that the command is on PATH or that `mise` exists. A probe such as `mise exec -- vp --version` would trigger a tool install inside a phase the script promises is side-effect-free, and the real invocation still fails before any live install or manager mutation.
- KTD3. **Verify the units after the install, before the manager.** The property that matters is that no manager mutation happens with an unverified unit, not that verification happens earliest. A rejected unit now leaves freshly installed but inert binaries in place; nothing is started, enabled, or reloaded.
- KTD4. **Model `ExecStart` resolution in the fixture stub.** The old `systemd-analyze` stub always succeeded, which is why the fixture never caught the deadlock. The stub now reads the unit, expands `%h`, and fails on a missing program — the exact behavior that produced the reported error text.

### Risks and Dependencies

- `mise exec` auto-installs missing tools and runs the repo's `postinstall` hooks on first use. That is the intended bootstrap path and requires the trust that `00-tools` already establishes; a container skips this provisioner entirely.
- The workspace install adds a network-dependent step to a fatal provisioner when the plugin component is stale. It matches what CI and the sibling builders already do, and a converged host never reaches it.
- Verification after the install means a malformed unit can leave a new binary on disk. The binary is inert until a manager starts it, and the next apply retries the whole transaction.

---

## Implementation Units

### U1. Resolve the build toolchain through mise (POSIX)

- **Goal:** Remove the dependency on an activated shell.
- **Requirements:** R1, R2, R3, R6 (mechanism per KTD1, KTD2).
- **Files:** `.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh.tmpl`
- **Approach:** Add `resolve_build_command` / `run_build_command`; resolve `vp` and `node` when the plugin is stale and `cargo` when the Rust components are stale; route the two `vp` calls, the `cargo` build, and both `node` validators through the resolver. Add the workspace `vp install --frozen-lockfile` ahead of the bundle build.
- **Verification:** U4 fixture cases for the mise fallback, the direct path, and the absent-toolchain boundary.

### U2. Verify startup definitions after the install (POSIX)

- **Goal:** Let a first apply install the binary the unit names.
- **Requirements:** R4, R5 (mechanism per KTD3).
- **Files:** `.chezmoiscripts/60-build/run_after_build-mxm4-haptic.sh.tmpl`
- **Approach:** Keep the unit-file existence and manager-reachability checks in preflight; move `systemd-analyze --user verify` into a `validate_unit` helper called between the atomic installs and `daemon-reload`, covering the notification bridge unit only when that component is being reconciled.
- **Verification:** U4 ordering assertions plus the `unit-validation` failure case.

### U3. Mirror the toolchain resolution on Windows

- **Goal:** Keep the counterparts aligned.
- **Requirements:** R6, R7.
- **Files:** `.chezmoiscripts/60-build/run_after_build-mxm4-haptic.ps1.tmpl`
- **Approach:** Replace the `vp`/`cargo` `Require-Command` entries with `Resolve-BuildCommand`, invoke both builds through `Invoke-BuildCommand` (Push-Location for an activated command, `mise -C … exec --` otherwise), and add the workspace install. `schtasks.exe` stays a hard requirement.
- **Verification:** PSScriptAnalyzer over the render, behavior tests of both helper branches, and the Windows provisioning fixture on its native runner.

### U4. Extend the fixtures to the reported failure

- **Goal:** Make issue #158 reproducible and permanently covered.
- **Requirements:** R8 (mechanism per KTD4).
- **Files:** `.ci/test-mxm4-haptic-provision.sh`, `.ci/test-mxm4-haptic-provision.ps1`, `.ci/test-mxm4-haptic-gates.sh`
- **Approach:** Give the fixture units a real `%h`-relative `ExecStart`; make the `systemd-analyze` stub resolve it; assert install < verify < daemon-reload on the first convergence; add a mise-only-toolchain case and a `plugin-deps` failure stage; move `unit-validation` to the post-install fatal group; teach both `vp` stubs the workspace install and assert it runs from the workspace root; update the Windows cargo-argument gate to the new argument-array form.
- **Verification:** The fixture passes against the fixed render and fails against the pre-fix render with the exact error text from the issue.

---

## Verification Contract

- **POSIX behavior:** Render both OS variants with `chezmoi execute-template` and run `.ci/test-mxm4-haptic-provision.sh` against the Linux render; re-run it against the pre-fix render and require the issue's failure.
- **Render gates:** `.ci/test-mxm4-haptic-gates.sh` and `.ci/test-mxm4-haptic-chezmoi-retry.sh`.
- **Static checks:** `bash -n` and `shellcheck --external-sources` over the rendered Linux and macOS scripts and the edited fixtures; PowerShell parse plus `Invoke-ScriptAnalyzer` (Error and Warning) over the rendered `.ps1` and the Windows fixture.
- **Windows behavior:** Helper-level tests of `Resolve-BuildCommand`/`Invoke-BuildCommand` on the rendered functions; the full Task Scheduler fixture runs on the native Windows CI leg.
- **Repository gates:** `git diff --check`, `git status`, and a scope-limited diff. Root `CLAUDE.md` and `packages/CLAUDE.md` stay exact `@AGENTS.md` mirrors.
- **No deployment:** No `chezmoi apply`; every check runs against a throwaway destination and scratch home.

## Definition of Done

- A fixture host with the toolchain reachable only through mise converges both components.
- A fixture host with nothing installed converges, verifying the unit after the install and before `daemon-reload`.
- The pre-fix render fails the fixture with `unit validation: mxm4-hapticd.service is invalid`.
- Absent toolchain, failed dependency install, failed build, invalid artifact, and invalid unit all stay fatal without mutating a manager.
- `AGENTS.md` records the toolchain-resolution rule and the verification-order rule.

---

## Sources and Research

- Issue #158 — reported first-apply failures and the `chezmoi state reset` workaround.
- `.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl:30-35` and `run_onchange_after_build-kimi-reconcile.sh.tmpl:19-20` — the established `mise -C … exec -- vp` builder pattern.
- `dot_config/mise/config.toml:10,34` and `mise.toml:2-8` — `viteplus`/`node` come from the global config, `rust` from the repo pin, and the repo's `postinstall` hook runs the workspace install.
- `dot_config/systemd/user/mxm4-hapticd.service.tmpl` and `mxm4-haptic-notify.service.tmpl` — `ExecStart=%h/.local/bin/…`, the paths `systemd-analyze verify` resolves.
- `.github/workflows/ci.yml:91-93` — CI installs the workspace before building the OMP bundle.
