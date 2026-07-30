---
title: Make omp Plugin Reconcile Idempotent - Plan
type: fix
date: 2026-07-30
topic: omp-plugin-reconcile-idempotency
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Make omp Plugin Reconcile Idempotent - Plan

## Goal Capsule

- **Objective:** Stop `chezmoi apply` from failing on re-runs because the omp compound-engineering reconcile script calls omp verbs that error on already-present state (`marketplace add` on a duplicate name; `install` on an already-installed plugin).
- **Product authority:** The user reported the live apply error and confirmed the scope is this single reconcile path.
- **Execution profile:** Two coupled template edits (POSIX + Windows) adopting the established `localArchive` remove→add→install sequence plus `install --force`, then updating the two CI call-shape assertions that pin the omp reconcile contract.
- **Open blockers:** None.

## Product Contract

### Summary

The omp compound-engineering plugin reconcile must be idempotent: a second `chezmoi apply` with no source change MUST succeed, and a ref bump (path change) MUST re-point the marketplace registration at the new path and reinstall the plugin. The fix reuses the pattern the sibling Claude/Codex installer already uses for `localArchive` marketplaces.

### Problem Frame

`.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.{sh,ps1}.tmpl` reconciles omp's compound-engineering plugin by running `omp plugin marketplace add "$SOURCE"` then `omp plugin install --scope user 'compound-engineering@compound-engineering-plugin'`. Verified against the installed omp binary, neither verb is idempotent:

- `omp plugin marketplace add <path>` exits 1 with `Error: Marketplace "compound-engineering-plugin" already exists` when the name is already registered. Because the POSIX half runs under `set -euo pipefail`, this aborts the script and fails the apply.
- `omp plugin install --scope user <plugin>@<market>` exits 1 with `is already installed. Use force option to reinstall.` when the plugin is present.

Both fire on every re-apply after the first successful install. omp also does not move an existing marketplace registration in place, so a ref bump (the `localArchive` source PATH changes) would leave the registration pointing at the stale path even if `add` were made to no-op. The sibling `run_onchange_after_install-agent-plugins.sh.tmpl` already solves this for Claude/Codex: for a `localArchive` marketplace it does `marketplace remove <name> → add <path> → install`, and documents that omp-style duplicates are exactly what the pre-`remove` prevents.

Verified omp behavior (current binary): `omp plugin marketplace remove compound-engineering-plugin` exits 0 even when the marketplace is absent (graceful), and `omp plugin install --scope user --force ...` is idempotent and serves the version-bump reinstall.

### Requirements

- R1. The POSIX reconcile script MUST NOT abort when the compound-engineering marketplace is already registered. It MUST drop the stale name-keyed registration before `add`.
- R2. The Windows reconcile script MUST satisfy R1's equivalent: it MUST issue the `remove` before `add` and MUST NOT throw on a `remove` that reports the marketplace absent.
- R3. Both scripts MUST reinstall the plugin idempotently using `--force`, which also covers a ref-bump reinstall.
- R4. The change MUST mirror the established `localArchive` remove→add→install sequence in `run_onchange_after_install-agent-plugins.sh.tmpl`; it MUST NOT introduce a new mechanism, a list/grep precheck, or error-string matching.
- R5. The omp-absent soft-skip, the pinned-path existence check, the `$SOURCE` resolution, and the resolved-version fingerprint trigger MUST remain unchanged.
- R6. The two CI call-shape assertions that pin the omp reconcile contract (`.ci/test-omp-agent-reconcile.sh` and the Windows step in `render-dotfiles.yml`) MUST be updated to the new three-call, `--force` shape. No live `chezmoi apply` is part of verification.

### Scope Boundaries

**In scope**

- `run_onchange_after_update-omp-plugins.sh.tmpl` and `run_onchange_after_update-omp-plugins.ps1.tmpl` reconcile bodies.
- The omp call-shape assertions in `.ci/test-omp-agent-reconcile.sh` and `.github/workflows/render-dotfiles.yml`.

**Non-goals**

- Changing the Claude/Codex `install-agent-plugins` installer (already idempotent).
- Changing the neutral marketplace data, the release-lock ref, the external archive, or the haptic extension flow.
- Adding omp-cli-version gating or a new fingerprint dependency for these scripts.
- Running a live `chezmoi apply` or starting the real omp user service.

### Acceptance Examples

- AE1. **Covers R1, R3.** Rendered POSIX script emits, in order: `plugin marketplace remove compound-engineering-plugin`, `plugin marketplace add "$SOURCE"`, `plugin install --scope user --force compound-engineering@compound-engineering-plugin`, then the success line.
- AE2. **Covers R2, R3.** Rendered Windows script issues `omp plugin marketplace remove compound-engineering-plugin` (exit code tolerated), then `add`, then `install --scope user --force ...`; it throws only on `add`/`install` failure, not on a benign `remove`.
- AE3. **Covers R4, R5.** A pre-edit vs post-edit render diff changes only the new `remove` line and the `--force` flag; the soft-skip, the `marketplace.json` existence check, the `$SOURCE`/`$ceVersion` resolution, and the OS gate are byte-identical.
- AE4. **Covers R6.** The POSIX CI test asserts exactly three recorded calls (remove, add, force-install) and the Windows workflow step asserts the same three-call shape.

## Planning Contract

### Key Technical Decisions

- KTD1. **Pre-`add` `marketplace remove` by name.** Chosen over ignoring the "already exists" error or grep-prechecking `marketplace list`: omp does not relocate an existing registration's path, so only a name-keyed remove guarantees a ref-bumped PATH is re-registered, and it is graceful (exit 0) when the marketplace is absent. This is the exact `localArchive` sequence the sibling installer uses for Claude and Codex.
- KTD2. **`install --scope user --force`.** Chosen over a list-precheck before install: omp's `install` errors on an already-installed plugin and `--force` is the documented reinstall path, which also serves the version-bump reinstall without a racy presence probe.
- KTD3. **Tolerate the remove exit code on both platforms.** The POSIX half uses `>/dev/null 2>&1 || true` (mirrors the sibling installer); the Windows half runs the remove without throwing on its exit code, so an absent marketplace on a first bootstrap never aborts the apply. Only `add` and `install` failures throw.
- KTD4. **Update both CI call-shape assertions in lockstep.** The POSIX test and the Windows workflow step record every omp invocation through a stub that always exits 0, so the new `remove` call becomes a recorded call and the `--force` flag changes the install string; both assertions must move from two calls to three and pin the new install string, or CI fails on the unchanged shape.

### Risks and Dependencies

- **omp `--force` availability:** Verified against the installed binary (the `omp plugin` help lists `--force  Force install`, and a live `install --force` on an already-installed plugin exits 0). If a future omp build dropped `--force`, the install step would fail loudly rather than silently — acceptable and observable.
- **Windows remove-on-absent exit code:** Cannot be exercised on this Linux host. The POSIX sibling proves remove is graceful on absent for the real binary; the Windows half tolerates the exit code regardless, so a non-zero-on-absent would be swallowed and the subsequent `add` would still register the marketplace.
- **Stub-vs-real divergence:** Both CI stubs record calls and exit 0 unconditionally, so they prove call shape, not omp's real merge semantics. The real-binary idempotency was verified by hand against the installed omp and is the documented manual probe, not a CI assertion.

## Implementation Units

### U1. Make the omp reconcile scripts idempotent

- **Goal:** Both platform reconcile scripts tolerate an already-registered marketplace and an already-installed plugin, and re-point the registration on a ref bump.
- **Requirements:** R1, R2, R3, R4, R5. Implements KTD1, KTD2, KTD3.
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`, `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.ps1.tmpl`.
- **Approach:** In the POSIX half, immediately before the existing `omp plugin marketplace add "$SOURCE"`, add `omp plugin marketplace remove compound-engineering-plugin >/dev/null 2>&1 || true` with a one-line comment naming the `localArchive` remove→add reason; change the install line to `omp plugin install --scope user --force 'compound-engineering@compound-engineering-plugin'`. In the Windows half, before the `& omp plugin marketplace add $source` block, add a tolerated `& omp plugin marketplace remove compound-engineering-plugin 2>$null` that warns but does not throw on a non-zero exit; change the install to `& omp plugin install --scope user --force 'compound-engineering@compound-engineering-plugin'`. Do not touch the omp-absent soft-skip, the `marketplace.json` existence check, the `$SOURCE`/`$ceVersion`/`$ceAuthority` resolution, the OS gate, or the rendered success line.
- **Patterns to follow:** The `localArchive` remove→add→install sequence and `>/dev/null 2>&1 || true` graceful-remove idiom in `.chezmoiscripts/70-agents/run_onchange_after_install-agent-plugins.sh.tmpl:260-286`.
- **Test scenarios:** `Test expectation: none — executable shell/PowerShell templates whose behavior is proven by the Verification Contract render + the real-binary manual probe, not a unit test.` The contract in U2 pins the call shape.
- **Verification:** Rendered POSIX script emits the three calls in AE1 order under `set -euo pipefail`; rendered Windows script emits the tolerated remove plus add plus force-install (AE2); a baseline render diff shows only the remove line and `--force` added (AE3).

### U2. Update the omp call-shape CI assertions

- **Goal:** The two CI assertions that pin the omp reconcile contract match the new three-call, `--force` shape.
- **Requirements:** R6. Implements KTD4.
- **Dependencies:** U1.
- **Files:** `.ci/test-omp-agent-reconcile.sh`, `.github/workflows/render-dotfiles.yml`.
- **Approach:** In `.ci/test-omp-agent-reconcile.sh`, change the recorded-call block from a two-call expectation to three: `calls[0] == "plugin marketplace remove compound-engineering-plugin"`, `calls[1] == "plugin marketplace add $source"`, `calls[2] == "plugin install --scope user --force compound-engineering@compound-engineering-plugin"`, and assert `${#calls[@]} -eq 3`. In the Windows step of `render-dotfiles.yml`, change `$actual.Count` from 2 to 3 and shift the assertions so `$actual[0]` is the remove, `$actual[1]` is the add, and `$actual[2]` is the `--force` install string. Leave every other assertion in both files unchanged.
- **Patterns to follow:** The existing assertion idioms in both files (bash `mapfile`+`[[ ]]` triple, PowerShell `$actual` index array).
- **Test scenarios:** `Test expectation: none — these ARE the test; their correctness is proven by running them against the rendered scripts in the Verification Contract.` 
- **Verification:** Run `.ci/test-omp-agent-reconcile.sh` against freshly rendered scripts through the isolated op-stub render path and confirm it passes with three calls (AE4); `bash -n` and the workflow's own `pwsh -File` stub execution confirm the Windows shape.

## Verification Contract

- **Render path.** Render both omp scripts through `chezmoi execute-template` with `--source "$PWD"`, a per-user scratch destination, a stub `op` (newline-free secrets), and an empty config — the isolated render recipe in `AGENTS.md`. No readiness marker, so the op stub covers the secret shims.
- **POSIX call shape.** The rendered `run_onchange_after_update-omp-plugins.sh` contains, in order: a `plugin marketplace remove compound-engineering-plugin` line that swallows stderr and `|| true`s; the existing `plugin marketplace add "$SOURCE"`; `plugin install --scope user --force 'compound-engineering@compound-engineering-plugin'`; the unchanged success `printf`. `bash -n` passes (AE1).
- **Windows call shape.** The rendered `.ps1` issues a tolerated `omp plugin marketplace remove compound-engineering-plugin 2>$null` (no throw on its exit code), then `add` (throws on failure), then `install --scope user --force ...` (throws on failure). `pwsh -NoProfile -Command` parse check passes, or the workflow stub proves execution (AE2).
- **Baseline diff.** A pre-edit vs post-edit rendered-script diff shows only the added remove line and the `--force` flag; soft-skip, existence check, resolution, OS gate, and success line are byte-identical (AE3).
- **CI test.** `.ci/test-omp-agent-reconcile.sh` passes against the freshly rendered POSIX plugin script through the existing isolated harness, asserting exactly three calls and the `--force` install string (AE4).
- **Scope check.** `git diff --check`, `git status`, and a scoped diff show only the two templates, the two assertion files, and this plan changed.
- **CI check if pushed.** `.github/workflows/ci.yml` and `.github/workflows/render-dotfiles.yml` reach terminal success.

## Definition of Done

- Both omp reconcile scripts satisfy R1-R5: idempotent on re-apply, ref-bump-safe, soft-skip and resolution unchanged.
- Both CI call-shape assertions satisfy R6 and AE4.
- Isolated render, `bash -n`, the POSIX reconcile test, and the scope diff all pass. Any pushed CI reaches terminal green.

## Sources / Research

- `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl` and `.ps1.tmpl` — the failing reconcile scripts.
- `.chezmoiscripts/70-agents/run_onchange_after_install-agent-plugins.sh.tmpl:260-286` — the established `localArchive` remove→add→install sequence and graceful-remove idiom this mirrors.
- `.chezmoidata/agents.yaml:192-198` — `compound-engineering-plugin` is `kind: localArchive` (PATH changes per ref bump), confirming the remove-before-add requirement.
- `.ci/test-omp-agent-reconcile.sh:58-72` and `.github/workflows/render-dotfiles.yml:821-841` — the omp call-shape assertions to update.
- Live omp binary verification — `marketplace add` errors on duplicate (exit 1); `marketplace remove <name>` is graceful on absent (exit 0); `install --scope user --force` is idempotent (exit 0); `omp plugin --help` lists `--force  Force install`.
