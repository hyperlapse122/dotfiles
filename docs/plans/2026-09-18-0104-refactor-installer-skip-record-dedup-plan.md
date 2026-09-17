---
title: Installer Skip-Record and Verdict De-duplication - Plan
type: refactor
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Installer Skip-Record and Verdict De-duplication - Plan

## Goal Capsule

- **Objective:** an operator reading a package installer, or adding the next one, finds the skip-record path and the .NET tool verdict stated once, so a future edit cannot leave one copy behind and report a host as converged on one OS while recording it as blocked on another.
- **Means:** apply the four review findings PR #542 left unapplied — a `clear_record` form on the shared skip partial, a single-copy .NET tool verdict body, an inlined Ubuntu devtools loop, and an annotated suppression idiom with a widened structural gate (KTD1, KTD2, KTD4, KTD5).
- **Authority:** the install verdict policy in `AGENTS.md` and `CONCEPTS.md` outranks every convenience in this plan. The skip declaration contract in `.chezmoitemplates/skip.sh.tmpl` and the site matrix in `.ci/skip-declaration-site-matrix.yaml` outrank any restructuring that would be tidier.
- **Execution profile:** structural refactor of rendered shell. The proof is that the rendered output does not change where it must not, and that the CI suites stay green.
- **Stop conditions:** stop and report if a change would alter a rendered declaration site's enclosing predicate, add or remove a declaration site, or change which packages a package manager is asked for.
- **Who finishes and ships:** this run implements, verifies and opens the pull request.

---

## Product Contract

### Summary

Four review findings from PR #542 are applied. The shared skip partial gains a fifth call form that emits the removal of its own state record, and the six hand-copied record paths in the package installers are replaced by calls to it. The .NET installer's tool verdict body stops being triplicated across its Fedora, Ubuntu and darwin branches and is emitted from one template region parameterised by a script identity derived once in the header. The Ubuntu devtools branch drops its `install_apt` helper and the one-off `devtools_attempted` flag for an inlined loop. The `if ! cmd; then :; fi` sites gain a comment naming the gate they exist for, and that gate is widened so `|| :` cannot become the next way around it.

### Problem Frame

PR #542 made the install verdict a post-attempt re-inspection of the declared set, and left four findings unapplied because the reviewer judged them scope decisions for a later run. Each one is a place where the same fact is written down more than once. The skip-record path `${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/<script>__<site>` is constructed by `.chezmoitemplates/skip.sh.tmpl` when a record is written and hand-copied into six `clear_*_skip_record` functions when it is removed, so the partial owns half of its own contract. The .NET tool verdict exists three times in one file, once per operating system, so a correction has to be made three times or it is not made. The Ubuntu devtools branch threads a flag through a helper to avoid a re-inspection that the policy wants unconditionally. And the `if ! cmd; then :; fi` idiom, which exists because the structural gate rejects `|| true`, carries nothing that says so, so it reads like evasion rather than compliance.

### Requirements

**Record path ownership**

- R1. `.chezmoitemplates/skip.sh.tmpl` owns the skip-record path for removal as well as for writing, through a `clear_record` call form that emits the removal of its own record.
- R2. Every `clear_*_skip_record` function in the package installers takes its record path from that form instead of a hand-copied literal. The six are the .NET Fedora, Ubuntu and darwin twins, the apps Fedora twin, and the devtools Fedora and Ubuntu twins.
- R3. `clear_record` emits no skip-declaration sentinel and no `exit` or `return`, and requires none of `reason`, `direction` or `probe`.

**.NET verdict de-duplication**

- R4. The .NET installer emits `compute_missing_dotnet_tools`, `report_dotnet_tools_missing` and `clear_dotnet_tools_skip_record` from one template copy rather than three. `install_dotnet_tools` stays branched, because the three branches differ in control flow and indentation rather than only in identity.
- R5. The rendered .NET installer is byte-identical on Fedora, Ubuntu and darwin to what the pre-change template renders, apart from two intended changes: the record-removal lines R2 routes through the partial, which stay textually identical, and the suppression-idiom comment R9 adds.
- R6. The darwin branch keeps its own control flow: it owns no `dotnet-absent` declaration site, and it does not clear its record when `dotnet` is absent.

**Ubuntu devtools loop**

- R7. The Ubuntu devtools branch installs packages without a one-off attempt flag and without the `install_apt` helper.
- R8. The set of packages `apt-get install` is asked for does not change. A package already installed when the loop reaches it — including one an earlier package pulled in as a Recommends dependency — is not requested.

**The suppression idiom and its gate**

- R9. The first `if ! cmd; then :; fi` site in each installer that uses it names the structural gate as the reason the idiom is written that way.
- R10. The structural gate rejects `|| :` on a declared-set install call exactly as it already rejects `|| true`, and a test proves the widened expression rejects it.

**Verdict preservation**

- R11. Convergence stays decided by post-attempt re-inspection of the declared set on every branch this plan touches, never by a package manager's exit status.
- R12. No declaration site is added, removed, or moved to a different enclosing predicate, so `.ci/skip-declaration-site-matrix.yaml` needs no edit.

### Key Decisions

- **All four findings land in this run, none is deferred to a tracker issue.** (session-settled: user-directed — chosen over filing one or more as follow-up issues: the request was to leave no unapplied finding behind.) Governs R1, R4, R7, R9.
- **PR #542's scope boundary on `.chezmoitemplates/skip.sh.tmpl` is spent.** That plan restricted the partial to one message change so its own diff stayed on the policy; that restriction was local to that PR and does not survive into this one. Governs R1, R3.

### Scope Boundaries

- The three installers this plan edits are the .NET, devtools and apps installers. The other package installers still awaiting conversion to the verdict policy are untouched.
- `prune_stale_skip_records`, `dotfiles-skips`, the four skip directions, and the sentinel shape are unchanged.
- No package is added to or removed from any declared set.

#### Deferred to Follow-Up Work

- Converting the remaining package installers named in `AGENTS.md` as awaiting the verdict policy. Out of this plan's scope and not a finding.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **`clear_record` is a fifth form on the existing partial, not a new partial.** It reuses the `script` and `site` identity the partial already validates and the `$file` path it already computes, so the write path and the clear path derive one string from one place. A separate partial would duplicate the identity gates and the path expression, which is the defect. Serves R1, R2.
- KTD2. **`clear_record` emits no sentinel and no terminator.** `.ci/check-skip-declarations.sh` observes sentinels and `exit`/`return` statements; a bare `rm -f` line produces neither, so the checker needs no change and the site matrix gains no row. Emitting a sentinel would instead require an owner row, an instance, a predicate digest and a continuation for a line that declares no early exit. Serves R3, R12.
- KTD3. **`reason` becomes conditional rather than optional in general.** The existing guard rejects an empty `reason` for all four current forms, and that guard is what makes every operator-facing message derivable. `clear_record` prints nothing, so the guard is scoped to the forms that print. `direction` and `probe` stay rejected for `clear_record` the way they are already rejected for `done_here` and `not_applicable`. Serves R3.
- KTD4. **The .NET de-duplication covers the three helper functions and stops there.** The repository's existing precedent for one body across OS branches is a header-derived variable — `.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl` derives `$abi`, `.chezmoiscripts/30-components/run_onchange_before_75-direct-rpms.sh.tmpl` derives `$rpmArch`, `.chezmoitemplates/sudo-elevation-guard.sh.tmpl` derives `$helper`. The three helpers differ across branches only in the script identity, so a header-derived identity collapses them exactly. `install_dotnet_tools` does not: Fedora and Ubuntu open with a `dotnet-absent` guard whose reason names a different package manager each, darwin has no such site and wraps its whole body in `if command -v dotnet`, and that wrapper moves the declaration a level deeper. Folding those into one copy would parameterise the control flow itself, which is what makes the render stop being provably identical. A shared `includeTemplate` partial was rejected for the same reason plus the prior plan's KTD5, which settled that a shared partial would need its own owner semantics in the site matrix. Serves R4, R6.
- KTD5. **Byte-identical render is the acceptance signal for the .NET de-duplication.** The declaration sites are pinned by a digest of their enclosing predicate and, on darwin, by a four-space indentation the Fedora and Ubuntu branches do not share. Comparing the rendered output before and after proves R5, R6 and R12 at once, and is cheaper and stricter than reasoning about which of those properties a restructuring preserved. Serves R5, R12.
- KTD6. **The Ubuntu loop keeps its per-package freshness check inside the loop.** Computing the missing set once and installing it would ask `apt-get` for a package an earlier package had already pulled in as a Recommends dependency, marking it manually installed instead of automatic. Checking each package immediately before its own attempt is what the deleted `install_apt` did, so inlining it — rather than hoisting the computation — is what makes the change a refactor instead of a behavior change. Serves R7, R8.
- KTD7. **`compute_missing_dev_packages` runs unconditionally after the loop.** The `devtools_attempted` flag existed to skip that call when nothing was attempted, where the missing set is empty either way. Dropping the flag costs one `dpkg-query` per declared package on a converged host and makes the post-attempt re-inspection the policy names unconditional. Serves R7, R11.
- KTD8. **The gate is widened and the idiom is annotated; the idiom itself stays.** `if ! cmd; then :; fi` is the sanctioned way to discard an install command's status under `set -e` without writing `|| true`. Replacing it with `cmd || :` would fail the widened gate, and replacing it with `|| true` would fail the existing one. The fix for a construct that reads like evasion is the comment that names what it is complying with. Serves R9, R10.

No bake-off: each finding's mechanism was settled by research rather than left open between structurally distinct candidates. KTD4 came closest — a shared partial against a header variable — and did not qualify because the prior plan's KTD5 already settled the site-matrix cost of a shared partial.

### Assumptions

- A1. Rendering the three installers for Fedora, Ubuntu and darwin before and after the change, and diffing, is available locally through the same `chezmoi execute-template` path `.ci/check-skip-declarations.sh` and `.ci/test-package-installer-verdict.sh` already use. If it is not, the byte-identical claim of KTD5 degrades to the assertions those suites already make.
- A2. The rendered content of all three installers changes, so chezmoi re-runs each of them once on every managed host. On a converged host that re-run performs inspections only. The Ubuntu devtools branch additionally runs its existing unconditional `apt-get update -qq`, as it does today.
- A3. `clear_record` reaching a path that should not clear a record stays impossible for the same reason it is impossible today: every failing verdict declares its skip with a `return 0` terminator before the clear twin is reached. The one exception the existing suite already covers is a report helper that returns non-zero.

### Risks

- The `clear_record` form emits no sentinel, so `.ci/check-skip-declarations.sh` cannot see it and cannot verify that a twin's `script`/`site` pair matches the declaration site that writes the same record. A typo in a `clear_record` argument would therefore fail silently at convergence rather than at CI. The mitigation is coverage, not a checker change: U1 asserts the emitted path for the form itself, and U2 asserts `no_record` on the converged path of every one of the six sites it converts, which is what would catch a mismatched pair.

### Sequencing

U1 before U2, because U2's call sites need the form to exist. U2 before U3, because the de-duplicated .NET body calls `clear_record` and hand-writing the path first and replacing it after would produce a render diff that hides the one KTD5 checks for. U4 and U5 are independent of the others; U5 comes last so its widened gate runs against the final rendered output.

---

## Implementation Units

### U1. Add the `clear_record` form to the skip partial

- **Goal:** `.chezmoitemplates/skip.sh.tmpl` accepts `form: "clear_record"` and emits only the removal of the record its `script` and `site` identify.
- **Requirements:** R1, R3, R12. Implements KTD1, KTD2, KTD3.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/skip.sh.tmpl`, `.ci/test-skip-declaration-gates.sh`.
- **Approach:**
  1. Add `clear_record` to the form allowlist, and extend the partial's header comment so the four-call-forms contract reads as five and states that the new one is not an early exit and declares nothing.
  2. Scope the `reason` guard to the forms that print a message, leaving the `script` and `site` guards and both identity charset gates applying to `clear_record` unchanged — they are what make the emitted path safe.
  3. Reject `direction` and `probe` for `clear_record` the way they are already rejected for the non-deferred forms, with a message naming the form.
  4. Add a branch that emits `rm -f <the computed record path> 2>/dev/null || true` and nothing else — no sentinel line, no terminator, no `printf`.
- **Patterns to follow:** the existing `done_here` branch for the `rm -f` line's exact text; the existing `$isSkip` guard structure for the conditional validation; the existing `fail` messages for wording and for naming `<script>/<site>` in the error.
- **Test scenarios:**
  - A fixture calling `clear_record` renders a single `rm -f` line whose path is `${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/<script>__<site>`, with no `# skip-declaration-v1` line and no `exit` or `return` anywhere in the emitted block.
  - A fixture calling `clear_record` with no `reason` renders successfully.
  - A fixture calling `clear_record` with a `direction` fails the render with a message naming the form.
  - A fixture calling `clear_record` with a `probe` fails the render with a message naming the form.
  - A fixture calling `clear_record` with a `site` containing a slash fails the render on the existing identity charset gate.
  - A fixture whose script contains a `clear_record` call and no early exit passes `.ci/check-skip-declarations.sh` with no finding, proving the checker does not treat the emitted line as an undeclared terminator.
  - The four existing forms still render exactly as before, and a `skip_here` call with no `reason` still fails.
- **Verification:** `.ci/test-skip-declaration-gates.sh` passes with the new cases, and `.ci/check-skip-declarations.sh` reports the same site totals as before the change.

### U2. Route the six clear twins through the new form

- **Goal:** no package installer contains a hand-written skip-record path.
- **Requirements:** R2, R5, R12. Implements KTD1.
- **Dependencies:** U1.
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_50-dotnet.sh.tmpl`, `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`, `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`.
- **Approach:**
  1. Replace the body of each of the six `clear_*_skip_record` functions with a `clear_record` call passing that function's existing `script` and `site` values. The six pairs are listed in R2; each function's current literal already encodes the pair, and the declaration site in the same branch confirms it.
  2. Leave the function names, their call sites and their position in each install function untouched. The darwin twin stays inside its `if command -v dotnet` wrapper, per R6.
  3. Confirm the rendered removal line is textually identical to the line it replaces, for all six.
- **Patterns to follow:** the indentation and `| trim | indent` shape of the existing `skip.sh.tmpl` call sites in the same three files.
- **Test scenarios:**
  - Rendering each of the three installers for its supported operating systems produces removal lines byte-identical to the pre-change render.
  - The devtools Fedora converged case still leaves no record.
  - The devtools Ubuntu converged case still leaves no record.
  - The apps Fedora converged case still leaves no record.
  - The .NET Fedora all-tools-installed case still leaves no record.
  - The .NET Fedora tools-install-fails case still leaves its `operator-blocking` record in place, proving the clear twin is still unreachable behind the declared skip.
- **Verification:** `.ci/test-package-installer-verdict.sh` and `.ci/check-skip-declarations.sh` pass, and a grep for `chezmoi/skips/` across `.chezmoiscripts/30-components/` returns only the NVIDIA installer's own variable-driven removal.

### U3. Emit the .NET tool verdict body from one copy

- **Goal:** the .NET installer's three tool-verdict helpers exist once in the template and every branch renders unchanged.
- **Requirements:** R4, R5, R6, R11. Implements KTD4, KTD5.
- **Dependencies:** U2.
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_50-dotnet.sh.tmpl`.
- **Approach:**
  1. Derive a script-identity variable in the template header beside the existing `$isFedora` / `$isUbuntu` / `$isDarwin` values, resolving to `install-dotnet-fedora`, `install-dotnet-ubuntu` or `install-dotnet-darwin`.
  2. Emit `report_dotnet_tools_missing`, `clear_dotnet_tools_skip_record` and `compute_missing_dotnet_tools` once, interpolating that identity into the two `printf` prefixes and into the `clear_record` call.
  3. Keep the darwin bash 3.2 comment attached to `compute_missing_dotnet_tools` on darwin only, so the shared emission does not add it to the Linux renders or drop it from the darwin one.
  4. Leave `install_dotnet_tools` branched per OS, unchanged. Per KTD4 its three branches differ in control flow, not only in identity: Fedora and Ubuntu open with the `dotnet-absent` guard and declare with the enclosing predicate at two spaces and the declaration at `indent 4`; darwin wraps its body in `if command -v dotnet`, owns no `dotnet-absent` site, and declares with the predicate at four spaces and the declaration at `indent 6`.
  5. Keep the parts that are genuinely per-OS where they are: the SDK install and its report helper, the shared-host and sudo-elevation guards, and the fingerprint header.
  6. Keep every expansion of the missing-tools array behind its `${#...[@]}` count test, which is what makes the darwin render safe under `set -u` on bash 3.2.
- **Technical design:** directional. The header resolves one identity; the three helpers are written once and read it. Everything whose shape differs per branch — which guards run, which wrapper encloses the loop, and therefore the declaration's indentation — stays expressed per branch.
- **Patterns to follow:** `.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl` and `.chezmoiscripts/30-components/run_onchange_before_75-direct-rpms.sh.tmpl` for header-derived identity; `.chezmoitemplates/sudo-elevation-guard.sh.tmpl` for a derived value feeding one unified body.
- **Test scenarios:**
  - The rendered Fedora, Ubuntu and darwin variants are byte-identical to the pre-change renders.
  - Covers R6. The existing `darwin-dotnet-absent` case still passes: with `dotnet` absent no record is written and no record is removed.
  - The existing `darwin-converged` case still passes: with `dotnet` present and every declared tool installed, the record is removed and no `dotnet tool install` runs.
  - The existing `darwin-tool-fails` case still passes: with `dotnet` present and one tool's install failing, the verdict records `operator-blocking`, the stderr names the missing tool and its by-hand command, and the record survives.
  - On Ubuntu with `dotnet` absent after the SDK attempt, the `dotnet-absent` site still records `transient-blocking` against the `dotnet-present` probe.
  - On Fedora with every declared tool installed, no `dotnet tool install` runs and the record is removed.
  - The rendered variants contain no `|| true` on a `dotnet tool install` line.

  Test expectation: no new case. The three darwin cases above already exist in `.ci/test-package-installer-verdict.sh` and this unit changes no behavior, so they are retained and re-run against the de-duplicated template rather than added.
- **Verification:** the render diff against the pre-change template is empty for all three operating systems; `.ci/test-package-installer-verdict.sh` passes unchanged; `.ci/check-skip-declarations.sh` reports unchanged site totals.

### U4. Inline the Ubuntu devtools install loop

- **Goal:** the Ubuntu devtools branch installs its packages without `install_apt` and without `devtools_attempted`, asking `apt-get` for exactly the packages it asks for today.
- **Requirements:** R7, R8, R11, R12. Implements KTD6, KTD7.
- **Dependencies:** none.
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`, `.ci/test-package-installer-verdict.sh`.
- **Approach:**
  1. Delete `install_apt` and the `devtools_attempted` variable.
  2. Inline the per-package body into `install_devtools`: for each declared package, check `apt_installed` immediately before its own attempt and skip it when it is already present, otherwise attempt it and print the existing per-package failure message on a non-zero status.
  3. Call `compute_missing_dev_packages` unconditionally after the loop.
  4. Leave `apt_installed`, `compute_missing_dev_packages`, `report_devtools_missing`, the `apt-get update` line and the declaration site's enclosing condition exactly as they are — R12 depends on that condition's text being unchanged.
  5. Retarget the test harness's region extraction. `.ci/test-package-installer-verdict.sh` extracts `devtools-ubuntu.region` starting at `^install_apt\(\) \{$`, which this unit deletes; without this step the suite fails at extraction before any scenario runs. Change that start anchor to `^apt_installed\(\) \{$`, which becomes the branch's first emitted function and still precedes the package array and `install_devtools`.
- **Test scenarios:**
  - Covers R8. Three declared packages where installing the first marks the second installed: `apt-get install` is called for the first and the third and never for the second, and the verdict is converged.
  - `apt-get install` fails for the second of three packages, the third is still attempted, and the record names the second.
  - Every declared package already installed: no `apt-get install` runs, the post-attempt re-inspection still runs, and the record is removed.
  - Every declared package missing and every install failing: the record is `operator-blocking` and names all of them.
  - `apt-get update` fails and the installs still run.
  - The rendered Ubuntu variant contains no `|| true` on its `apt-get install` line.
- **Verification:** `.ci/test-package-installer-verdict.sh` passes with the new dependency-skipping case; `.ci/check-skip-declarations.sh` reports the `install-devtools-ubuntu/dev-packages-not-installed` site unchanged, proving the predicate digest still matches.

### U5. Annotate the suppression idiom and widen its gate

- **Goal:** a reader of `if ! cmd; then :; fi` learns why it is written that way, and `|| :` cannot become the next way around the gate.
- **Requirements:** R9, R10. Implements KTD8.
- **Dependencies:** U3, U4, so the widened gate runs against the final rendered output.
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`, `.chezmoiscripts/30-components/run_onchange_before_50-dotnet.sh.tmpl`, `.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`, `.ci/test-package-installer-verdict.sh`.
- **Approach:**
  1. Add a comment above the first `if ! cmd; then :; fi` site in each of the three installers that uses the idiom, naming the structural gate, saying the exit status is deliberately discarded because the post-attempt re-inspection is the verdict, and saying `|| true` is not available here. All three are in scope: the devtools branches, the .NET tool and SDK installs, and the apps installer's declared-set `dnf install`.
  2. Widen the gate expression so a declared-set install call followed by `|| :` fails it exactly as `|| true` does, keeping the existing Terra bootstrap allowance.
  3. Add an assertion that the widened expression actually rejects a `|| :` sample, so the widening is proved rather than assumed.
- **Patterns to follow:** the existing gate block's `offenders` / `fail` / `pass` shape and its Terra allowance.
- **Test scenarios:**
  - The widened expression matches a sample `dnf install -y foo || :` line.
  - The widened expression matches a sample `apt-get install -y foo || :` line.
  - The widened expression matches a sample `dotnet tool install -g foo || :` line.
  - The widened expression still matches the `|| true` forms it matches today.
  - The Terra bootstrap line is still allowed by the widened expression.
  - The widened expression does not match an install line whose only colon is legitimate — a `--repofrompath 'terra,https://…'` URL, a `${VAR:-default}` expansion — so the widening adds no false positive.
  - Every rendered variant of the three installers passes the widened gate.
- **Verification:** `.ci/test-package-installer-verdict.sh` passes, including its gate block and the new rejection assertions.

---

## Verification Contract

| Check | Applies to | What it proves |
|---|---|---|
| Render diff of the three installers before and after, per OS | U2, U3 | R5, R6 — the de-duplication and the record-path routing changed no rendered byte except where intended |
| `.ci/test-package-installer-verdict.sh` | U2, U3, U4, U5 | the verdict, the record, its direction, the stderr text and the calls made, plus the widened structural gate |
| `.ci/check-skip-declarations.sh` | U1, U2, U3, U4 | R12 — the rendered surface still matches the site matrix, with unchanged owner and instance totals |
| `.ci/test-skip-declaration-gates.sh` | U1 | R1, R3 — the new form's render output, its relaxed and its retained guards |
| `.ci/test-dotfiles-skips.sh` | U1, U2 | the record format the clear path removes is still the one the reporter reads |
| `.ci/test-skip-record-pruning.sh` | U1, U2 | the pruner's treatment of each direction is unaffected |
| `.ci/test-ci-wiring.sh` | all | every `.ci` script this plan touches is still reachable from a workflow |
| `bash -n` on every rendered variant | U2, U3, U4, U5 | the emitted shell still parses on every supported OS |

---

## Definition of Done

- Every one of the four findings is applied. None is deferred, filed, or recorded as a known limitation.
- Across the three converted package installers — .NET, apps and devtools — `.chezmoitemplates/skip.sh.tmpl` is the only place a skip-record path is written, for both writing and removal. The NVIDIA installer's variable-driven line and the omp-settings script's two removals are outside this plan's scope and are untouched.
- The .NET installer's three tool-verdict helpers appear once in its template.
- The Ubuntu devtools branch contains no `install_apt` and no `devtools_attempted`.
- Every `if ! cmd; then :; fi` site that needed an explanation has one, and the gate rejects `|| :`.
- The rendered .NET installer is byte-identical per OS apart from the two intended changes R5 names: the record-removal routing and the suppression-idiom comment.
- Every check in the Verification Contract passes.
- No declaration site was added, removed, or re-anchored, and `.ci/skip-declaration-site-matrix.yaml` is unchanged.
- No abandoned or experimental code from a discarded approach remains in the diff.

---

## Sources & Research

- `docs/plans/2026-09-17-2131-fix-installer-failure-policy-plan.md` — the plan PR #542 implemented. Its KTD5 settled the per-OS script identities and rejected a shared partial for the declaration sites; its line 81 deferred the .NET hoist this plan now takes; its R8 and Ubuntu test scenario constrain the loop rewrite.
- `.chezmoitemplates/skip.sh.tmpl` — the form allowlist, the guard ladder, the identity charset gates, and the `$file` path expression the new form reuses.
- `.ci/check-skip-declarations.sh` — observes sentinel lines and `exit`/`return` terminators only, which is why a sentinel-free, terminator-free form needs no checker change.
- `.ci/test-package-installer-verdict.sh` — the stub-driven scenario harness, the region extraction boundaries, and the structural `|| true` gate this plan widens.
- `.ci/skip-declaration-site-matrix.yaml` — the owner rows for the six sites, including the darwin `dotnet-tools-not-installed` row anchored at four-space indentation and the absence of a darwin `dotnet-absent` row.
- `.chezmoiscripts/00-tools/run_onchange_after_android-sdk.sh.tmpl`, `.chezmoiscripts/30-components/run_onchange_before_75-direct-rpms.sh.tmpl`, `.chezmoitemplates/sudo-elevation-guard.sh.tmpl` — the header-derived-variable precedent KTD4 follows.
- `AGENTS.md`, `CONCEPTS.md` — the install verdict policy and the declared skip contract this plan must not weaken.
- No learning under `docs/solutions/` binds any of the four findings; the nearest, `fedora-akmods-builder-missing-nvidia-mok-deadlock.md`, records why a tool's exit status is not the verdict, which the policy already carries.
