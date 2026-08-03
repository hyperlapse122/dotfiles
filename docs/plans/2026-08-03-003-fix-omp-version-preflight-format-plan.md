---
title: Accept omp Name-Prefixed Version Output in update-omp-plugins Preflight - Plan
type: fix
date: 2026-08-03
topic: omp-version-preflight-format
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Accept omp Name-Prefixed Version Output in update-omp-plugins Preflight - Plan

## Goal Capsule

- **Objective:** Stop `chezmoi apply` from dying with `update-omp-plugins: preflight: expected omp 17.2.4, got omp/17.2.4` by making the reconciler's version gate accept the real `omp --version` output format on both platform halves.
- **Product authority:** The user reported the live preflight error; the real binary's output was verified on this host.
- **Execution profile:** Two coupled template regex fixes that mirror the established `.ci/test-omp-real-plugin.sh` delimiter pattern, plus CI stub alignment and executed accept/reject coverage.
- **Open blockers:** None.

---

## Product Contract

### Summary

The omp plugin reconciler's version preflight must accept the locked version wherever `omp --version` prints it as a non-digit-delimited token — `omp/17.2.4`, `omp 17.2.4`, or bare `17.2.4` — and must keep rejecting every other version, including digit-adjacent decoys. The CI omp stubs must answer `--version` in the real binary's `omp/<version>` format so the gate is tested against reality, not against a format the binary never produces.

### Problem Frame

`omp --version` prints `omp/17.2.4` (verified live on this host, exit 0). The POSIX reconciler gates on `(^|[[:space:]])${EXPECTED_OMP_VERSION}([[:space:]]|$)` and the Windows half on the `(^|\s)...(\s|$)` equivalent. Both require whitespace or string start immediately before the version token. The real output has `/` before the token, so every eligible host fails the preflight and the apply dies. The defect shipped because both CI stubs answer `--version` with the bare version, which the whitespace-anchored regex accepts at string start — CI never exercised the real format. The repo already knows the real format in two places: `.agents/skills/sync-omp-models/SKILL.md:80` parses it with `omp --version | cut -d/ -f2`, and `.ci/test-omp-real-plugin.sh:14-15` matches the locked version with non-digit delimiters and escaped dots.

### Requirements

- R1. The POSIX reconciler preflight accepts the locked version when `omp --version` reports it as a token preceded by start-of-string or a non-digit and followed by a non-digit or end-of-string.
- R2. The Windows reconciler preflight enforces the same acceptance rule and keeps the same failure diagnostic.
- R3. Both preflights reject a mismatched version, including a digit-adjacent decoy such as reported `omp/917.2.4` and a suffixed prerelease decoy such as reported `omp/17.2.4-rc.1`, against locked `17.2.4`.
- R4. Both CI omp stubs answer `--version` in the real binary's `omp/<version>` format, and the executed suite covers the accept, mismatch, and digit-adjacent cases.

### Scope Boundaries

**Non-goals**

- `.ci/test-omp-real-plugin.sh` and `.agents/skills/sync-omp-models/SKILL.md` already handle the `omp/` format; no changes there.
- No change to the expected-version source: `release-lock-ref.tmpl` and `.chezmoidata/releases.json` stay as they are.
- No change to marketplace reconciliation, plugin install, or haptic proof-gate behavior; only the version preflight match changes.

**Deferred to Follow-Up Work**

- Smoking the rendered reconciler preflight against the real `omp` binary in the existing real-binary CI job (the job that runs `.ci/test-omp-real-plugin.sh`) would close the stub-circularity gap: today every executed preflight check runs against stub-emitted strings calibrated from a single-host observation.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Mirror the `test-omp-real-plugin.sh` delimiter pattern in both reconciler halves.** Replace the whitespace-anchored regex with `(^|[^[:digit:]])<version>([^[:digit:]-]|$)` in the POSIX half and `(^|[^\d])<version>([^\d-]|$)` in the Windows half. This keeps one in-repo convention for "does this omp binary match the locked version" (`.ci/test-omp-real-plugin.sh:14-15`). The leading non-digit delimiter accepts `/`, space, and `v` prefixes while rejecting the digit-adjacent decoy R3 names; the trailing class additionally excludes `-` so a suffixed prerelease like `omp/17.2.4-rc.1` fails the gate, while a space-separated extra field still passes (per KTD4). Chosen over adding `/` to the whitespace class: that would create a second convention beside the existing one and would keep accepting digit-adjacent and suffixed false matches.
- KTD2. **Escape the version's dots in the POSIX pattern through a derived variable** (`${EXPECTED_OMP_VERSION//./\\.}`), as `.ci/test-omp-real-plugin.sh:14` does. The current unescaped `.` matches any character, a latent false accept. The Windows half already uses `[regex]::Escape` and needs no new escaping.
- KTD3. **Make the CI stubs realistic and add negative coverage instead of only fixing the regex.** Both stubs answer `--version` with `omp/<locked-version>`, and an override environment variable drives the executed reject cases in both platform suites. The bare-version stub is why the defect passed CI; fixing only the regex would leave the suite blind to the real format.
- KTD4. **Keep the check a delimited-token search over the whole `--version` output** rather than parsing an exact line format, so extra fields in future version output do not break the gate.

### Assumptions

- `omp --version` prints the same `omp/<version>` form on macOS and Windows; one codebase serves all platforms, and the Windows CI job's executed reconcile test covers the Windows half against the corrected stub.

---

## Implementation Units

### U1. POSIX preflight accepts the real version format

- **Goal:** The rendered POSIX reconciler accepts `omp/<locked>` output and rejects mismatches.
- **Requirements:** R1, R3 (mechanism per KTD1, KTD2, KTD4).
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`
- **Approach:**
  1. Derive a dot-escaped variant of `EXPECTED_OMP_VERSION` beside the `readonly` declaration (per KTD2).
  2. Replace the preflight regex's `(^|[[:space:]])` / `([[:space:]]|$)` anchors with `(^|[^[:digit:]])` / `([^[:digit:]-]|$)` and substitute the escaped variant (per KTD1).
  3. Keep the `preflight: expected omp ... got ...` diagnostic text unchanged.
- **Patterns to follow:** `.ci/test-omp-real-plugin.sh:14-15` — the delimiter pattern and the dot-escaping idiom.
- **Test scenarios:** Behavior is proven by U3's executed accept/reject cases, which run the rendered script. Render-level expectations: `bash -n` passes, and the rendered script carries the dot-escaped, non-digit-delimited pattern (pinned by the Verification Contract).
- **Verification:** The rendered script accepts a stub emitting `omp/<locked>` and rejects `omp/0.0.0` and `omp/9<locked>` when U3's suite runs.

### U2. Windows preflight accepts the real version format

- **Goal:** The rendered Windows reconciler enforces the same acceptance rule as the POSIX half.
- **Requirements:** R2, R3 (mechanism per KTD1, KTD4).
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.ps1.tmpl`
- **Approach:** Replace the `-notmatch` pattern's `(^|\s)` and `(\s|$)` anchors with `(^|[^\d])` and `([^\d-]|$)`. `[regex]::Escape($expectedOmpVersion)` already handles dots (per KTD2). Keep the `Fail` diagnostic text unchanged.
- **Patterns to follow:** The same decision source as U1; the ps1 half re-derives rather than sharing a rendered block, per the established pairing precedent.
- **Test scenarios:** The Windows CI job executes `.ci/test-omp-agent-reconcile.ps1` against the rendered ps1 with the U3-corrected stub, proving the accept path. Render-level expectations: the rendered ps1 parses and carries the non-digit-delimited pattern (pinned by the Verification Contract).
- **Verification:** The Windows CI job's executed reconcile test passes against a stub emitting `omp/<locked>`.

### U3. CI stubs emit the real version format and execute reject coverage

- **Goal:** The reconcile suite tests the version gate against the real binary's output format and proves both reject paths.
- **Requirements:** R3, R4 (mechanism per KTD3).
- **Dependencies:** U1, U2 — the reject cases only pass once the gates use the corrected pattern.
- **Files:** `.ci/test-omp-agent-reconcile.sh`, `.ci/test-omp-agent-reconcile.ps1`
- **Approach:**
  1. Change both stubs to answer `--version` with `omp/<locked-version>` instead of the bare version, with an override environment variable (e.g. `OMP_STUB_VERSION`) replacing the whole emitted string when set.
  2. Extend the POSIX suite's `run_plugins` helper and the Windows suite's invoke helper to pass the override through for negative runs.
  3. Add the executed cases below before the happy-path reconcile run, so a failing gate cannot record marketplace calls. Mirror the same reject cases in the Windows suite so R3's "both preflights" wording is executed, not render-pinned only.
- **Patterns to follow:** The suite's existing fail-path idiom (`run_plugins` with `OMP_FAIL_MATCH`, capturing stderr and asserting the diagnostic, asserting no success side effects).
- **Test scenarios:**
  - Happy path: the stub emits `omp/<locked>` (real format); the existing reconcile run succeeds end to end with all current assertions unchanged.
  - Bare format: the stub emits bare `<locked>`; the reconcile run still succeeds (backward-compatible acceptance, R1).
  - Mismatch: the stub emits `omp/0.0.0`; the rendered reconciler exits nonzero, stderr contains `preflight: expected omp`, and no `plugin marketplace add` call is recorded. Executed in both platform suites.
  - Digit-adjacent decoy: the stub emits `omp/9<locked>`; the reconciler fails the same way (proves the leading-delimiter half of R3). Executed in both platform suites.
  - Suffix decoy: the stub emits `omp/<locked>-rc.1`; the reconciler fails the same way (proves the trailing-delimiter half of R3). Executed in both platform suites.
  - The ps1 stub emits `omp/<locked>` by default so the Windows CI job exercises the accept path against the real format.
- **Verification:** `.ci/test-omp-agent-reconcile.sh` passes against freshly rendered scripts with the new cases included.

---

## Verification Contract

- **Render path.** Render both reconciler templates through `chezmoi execute-template` with the isolated recipe from `AGENTS.md`: per-user scratch destination, stub `op` returning newline-free secrets, empty config, `--source "$PWD"`; add `--override-data '{"chezmoi":{"os":"windows"}}'` for the ps1 half. No readiness marker, so the op stub covers the secret shims.
- **POSIX render.** The rendered script passes `bash -n` and its preflight line carries the dot-escaped, non-digit-delimited pattern.
- **Windows render.** The rendered ps1 parses (`pwsh -NoProfile` parse check when available locally) and carries the non-digit-delimited pattern; the existing CI PowerShell analyzer gate stays green.
- **Executed suite.** Build the haptic package per `.github/workflows/ci.yml` (`packages` install, then `build:omp-plugin`) and run `.ci/test-omp-agent-reconcile.sh` against the freshly rendered scripts. All existing assertions plus U3's new accept/reject cases pass.
- **Diff hygiene.** `git diff --check` passes; the diff touches only the four files named in the units.

## Definition of Done

- A stub emitting the real `omp/17.2.4` output passes the rendered POSIX preflight, and the Windows half enforces the same rule.
- Mismatched (`omp/0.0.0`), digit-adjacent (`omp/9<locked>`), and suffixed (`omp/<locked>-rc.1`) versions fail the preflight with the unchanged diagnostic before any marketplace mutation, executed on both platform halves.
- `.ci/test-omp-agent-reconcile.sh` passes against freshly rendered scripts, with the stubs emitting the real format.
- The diff is limited to the four named files; no abandoned-attempt scaffolding remains.

---

## Sources and Research

- `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl:83-85` — the failing POSIX gate.
- `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.ps1.tmpl:50-51` — the failing Windows gate.
- `.ci/test-omp-real-plugin.sh:14-15` — the established correct delimiter pattern and dot-escaping idiom.
- `.agents/skills/sync-omp-models/SKILL.md:80` — prior art that already parses the `omp/` prefix.
- `.ci/test-omp-agent-reconcile.sh:149-150` and `.ci/test-omp-agent-reconcile.ps1:50` — the unrealistic bare-version stubs that let the defect pass CI.
- Live verification on this host: `omp --version` prints `omp/17.2.4`, exit 0.
