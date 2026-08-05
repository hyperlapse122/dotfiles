---
title: Drop Windows Support and Trim CI - Plan
type: refactor
date: 2026-08-05
topic: drop-windows-trim-ci
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Drop Windows Support and Trim CI - Plan

## Goal Capsule

- **Objective:** Drop Windows as a managed platform and reduce CI/CD to a minimal set of build/lint/render guards plus two behavioral regression guards, retiring the forward-looking cutover apparatus and redundant jobs.
- **Product authority:** This plan owns the combined Windows-removal + CI-trim effort. No surrounding areas are active scope.
- **Open blockers:** None — all product decisions were resolved in the brainstorm.
- **Execution profile:** Source-tree and CI changes (`execution: code`).

---

## Product Contract

### Summary

Remove Windows support entirely and collapse CI/CD to core build/lint/render guards. The repo manages Fedora + macOS only; the per-plan/cutover CI machinery accumulated from earlier cross-platform work is retired, except two cheap behavioral regression guards the core guards cannot replace.

### Problem Frame

Windows exists in this repo only as CI-validated parity — the user never applies these dotfiles to a real Windows machine — yet it costs roughly five Windows runners, paired `.ps1` twins across every provisioning area, Windows-only data, and OS gates woven through the template tree. Separately, plans each left behind CI jobs (some now functioning regression guards, some a forward-looking Kitty→WezTerm cutover apparatus guarding an event that has not happened). The job count is high relative to the ongoing value each job provides. This plan removes a platform nobody uses and trims CI to what still earns its place.

### Key Decisions

- KD1. **Apply-surface cutover for Windows removal** (session-settled: user-directed — revised from "full clean cutover" after planning research showed the full surface includes the release-resolution subsystem; chosen over "full source purge": remove Windows as a managed apply target without rewriting the release-lock generator and hourly CI). Governs R1, R2, R3, R4.
- KD2. **Maximal CI simplification, accepting coverage loss** (session-settled: user-directed — chosen over "core + provisioning smoke": the user wants the minimal job set and accepts losing real-OS provisioning regression coverage). Governs R5, R6, R7, R8.
- KD3. **Keep two behavioral regression guards** (session-settled: user-directed — chosen over "retire all six" and "keep all six": `tmux-kitty-passthrough` and `compound-engineering-overlays` test behavior the core guards cannot, cheaply). Governs R6, R7.
- KD4. **Abandon the forward-looking Kitty→WezTerm cutover gatekeeping.** The cutover apparatus guards an uncertain-timeline future event; retire it and handle the WezTerm cutover manually if it matures. Governs R5.

### Requirements

**Windows platform removal**

- R1. Windows ceases to be a managed apply target. Windows provisioning source is removed: `.ps1` scripts and their `.chezmoiscripts` Windows-gated templates, the `20-windows`/`30-windows` script directories, `dot_local/bin` Windows shims, `.chezmoidata/visualstudio.yaml`, the per-capability `windows:` stanzas in `.chezmoidata/packages.yaml`, the Windows facts mirror, and `.chezmoiignore`/`.chezmoiremove` Windows rules. The POSIX `.sh.tmpl` twins' `ne .chezmoi.os "windows"` gates collapse to unconditional.
- R2. Cross-platform features keep their Linux+macOS structure and drop only the Windows branch — mxm4-haptic's Task Scheduler daemon path and the omp/figma/garden/GPG/compound-engineering `.ps1` provisioner twins.
- R3. Managed instructions (`AGENTS.md` and composed agent instructions) drop every Windows-parity rule: the haptic Task Scheduler runtime, omp Windows deployment, the facts Windows mirror, the tmux Windows exclusion, and the POSIX/`.ps1` alignment requirement.
- R4. `docs/plans/` Windows plan files remain as historical records and are not deleted.

**CI/CD trimming**

- R5. All Windows CI surface is removed: the `mxm4-haptic-windows` and `native-windows-x64` jobs, `apply-windows` and `lint-powershell`, the `windows` legs of the `figma-skills-native`/`rust-crate` matrices, and the `windows-arm64` device leg.
- R6. The cutover apparatus is retired entirely: `evaluator-gates`, `support-matrix`, `native-fedora-x64`, `native-macos-arm64`, `device-smoke.yml`, and the `.ci/cutover-gates.json` policy with its evaluator/validator scripts, schemas, and the `.ci/support-matrix.json` contract. This abandons the forward-looking Kitty→WezTerm gatekeeping.
- R7. Four lightweight regression guards retire: `garden-registry-relocation`, `secrets-cache-removal`, `ydotool-integration`, `kitty-provisioning`.
- R8. Two behavioral regression guards stay because they test behavior the core guards cannot: `tmux-kitty-passthrough` (real tmux Kitty-graphics passthrough) and `compound-engineering-overlays` (persona injection, idempotency, symlink reclamation).
- R9. Core build/lint/render guards stay: `omp-agent-integration` (simplified — drops the Windows `.ps1` cross-half render/compare), `ts-workspace`, `figma-skills-native` (ubuntu+macos), `rust-crate` (ubuntu+macos); and `render-dotfiles.yml` `apply`, `render-internals`, `apply-macos`, `shellcheck`, `gate`.
- R10. `refresh-release-lock.yml` stays unchanged. `releases.json` retains its `windows-*` keys as inert entries (never resolved on a Linux/macOS target); the full release-subsystem purge is deferred.
- R11. CI required-check gates stay valid — no aggregate `needs:` list or branch-protection rule references a removed job.

### Scope Boundaries

- macOS remains a supported platform (apply-render plus the figma/rust macos matrix legs); only its native provisioning CI smoke is removed.
- The Kitty→WezTerm terminal cutover itself is not happening now; only its gatekeeping apparatus is removed.
- `refresh-release-lock.yml` stays as the hourly release-lock refresher, minus Windows platform keys.
- `docs/plans/` Windows plan files stay as historical records.
- Workflow-file consolidation (merging `ci.yml` and `render-dotfiles.yml`) is not decided here — deferred to planning.
- The release-resolution subsystem is NOT purged: `.chezmoiexternals/*.toml` keep their `replace "windows" …` extension/path ternaries and per-tool Windows branches, and `.chezmoidata/releases.json` keeps its `windows-*` keys. These references are inert on Linux/macOS. Full source purge (incl. the `packages/release-lock` generator) is a documented follow-up.

### Dependencies / Assumptions

- A1. Windows is CI-validated parity only — the user does not apply these dotfiles to a real Windows machine, so removal is loss-free for daily use. Windows is exercised in CI, but no real-machine apply target exists.
- A2. The six jobs born from plans are functioning regression guards, not spent one-time validators — each test script self-identifies as a guard and runs on every push/PR. Retiring four of them loses real coverage (accepted per KD2).
- A3. The cutover apparatus is forward-looking, not spent — gates G0/G1a/G1b are all `status: "closed"`, guarding a Kitty→WezTerm cutover that has not happened.
- A4. `omp-agent-integration` (a kept guard) currently force-renders the Windows `.ps1` halves to compare both sides; it stays but its test surface shrinks when Windows goes.

### Outstanding Questions

- OQ1. (Deferred to planning) Keep a slim `delivery`/`gate` aggregate over the surviving jobs, or let branch protection reference the surviving jobs directly.
- OQ2. (Deferred to planning) Consolidate `ci.yml` and `render-dotfiles.yml` into one workflow now that the job set is small.

### Sources / Research

- CI surface: `.github/workflows/ci.yml`, `.github/workflows/render-dotfiles.yml`, `.github/workflows/device-smoke.yml`, `.github/workflows/refresh-release-lock.yml`.
- Cutover contract and status: `.ci/cutover-gates.json` (G0/G1a/G1b closed), `.ci/support-matrix.json` (five-target support contract), the `evaluator-gates` job at `.github/workflows/ci.yml`.
- Origin of the cutover apparatus: `docs/plans/2026-08-03-004-feat-cross-platform-workstation-parity-plan.md`, `docs/plans/2026-08-02-002-feat-cross-platform-omp-haptic-plugin-plan.md`.
- Platform-removal precedent: `docs/plans/2026-07-23-001-refactor-remove-ubuntu-studio-support-plan.md`.
- Windows plan records kept as history: `docs/plans/2026-08-04-001-feat-windows-vs2026-toolchain-plan.md`, `docs/plans/2026-08-04-002-fix-windows-codegraph-external-path-plan.md`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Apply-surface scope boundary.** The release-resolution subsystem (`.chezmoiexternals/*.toml` extension/path ternaries, `.chezmoidata/releases.json` windows keys, `packages/release-lock` generator) is left intact; its windows references are inert on Linux/macOS. Purging it is a follow-up. Instantiates KD1; Governs R1.
- KTD2. **`omp-agent-integration` loses its Windows cross-half.** The kept guard currently force-renders the `.ps1` halves to compare both sides (`.github/workflows/ci.yml:64-95`) and passes `.ps1` paths to `.ci/test-omp-agent-reconcile.sh`. Both go; the guard keeps its Linux render + reconcile. Governs R9.
- KTD3. **Delete-orphan-only for `.ci/` scripts.** Before deleting any `.ci/` test script, grep `.github/workflows/` for its callers; delete only scripts whose every caller is a removed job. Surviving jobs (`omp-agent-integration`, `figma-skills-native`, `tmux-kitty-passthrough`, `compound-engineering-overlays`) keep their scripts. Governs U7.
- KTD4. **Verification = scratch-render harness + CI.** Local checks use the AGENTS.md scratch harness (per-user scratch dir, newline-free `op` stub, `--source "$PWD"`, `execute-template` on changed `.tmpl`; scripts compared as rendered text; never deploy live `$HOME`). CI is the primary merge gate. Governs the Verification Contract.

### Sequencing

U1–U3 (source/data/gates) and U4 (docs) are independent and may proceed together. U5–U6 (CI trimming) land after the source state is final so CI reflects it. U7 (cutover apparatus + retired scripts) is independent of U1–U4. The `delivery`/`gate` aggregate repoint (U5/U6) is the last CI edit. Render-check runs after every template-touching unit.

## Implementation Units

### U1. Remove Windows provisioning scripts and bin shims

- **Goal:** Windows is no longer an apply target — delete every Windows-only executable/template.
- **Files:** all 16 `.ps1.tmpl` under `.chezmoiscripts/`; the `.chezmoiscripts/20-windows/` and `30-windows/` directories; `dot_local/bin/executable_code.ps1`, `dot_local/bin/executable_encryption-status.ps1`, `dot_local/bin/private_executable_import-wifi-1password.ps1.tmpl`; `.install-prerequisites.ps1`.
- **Patterns:** clean deletion; the POSIX `.sh.tmpl` twins become the sole provisioners.
- **Test Scenarios:** no `.ps1`/`.ps1.tmpl` remains under `.chezmoiscripts/` or `dot_local/bin/`; `.install-prerequisites.ps1` gone; affected directories render via `execute-template` without the deleted files.
- **Verification:** render-check; `git diff --check`.

### U2. Collapse Windows OS-gates in POSIX templates

- **Goal:** `.sh.tmpl` twins' `{{ if ne .chezmoi.os "windows" }}` / `{{ if eq .chezmoi.os "windows" }}` guards become unconditional.
- **Files:** every `.sh.tmpl` carrying a windows gate — `00-tools/{run_after_compound-engineering-overlays,run_once_before_mise-trust,run_onchange_after_codegraph,run_onchange_after_compound-engineering}.sh.tmpl`; `10-auth/{run_once_after_auth-tailscale,run_onchange_after_auth-dockerhub,run_onchange_after_auth-gitlab,run_onchange_after_auth-tokscale,run_onchange_before_auth-github}.sh.tmpl`; `70-agents/{run_after_config-omp-auth,run_after_config-omp-settings,run_onchange_after_update-omp-plugins,run_after_install-figma-skills}.sh.tmpl`; `80-keys/run_once_before_import-gpg-key.sh.tmpl`; `90-src/run_onchange_after_reconcile-garden.sh.tmpl`; `60-build/run_after_build-mxm4-haptic.sh.tmpl`.
- **Patterns:** remove the gate line and its matching `{{- end }}`; keep the body verbatim; no orphaned `end`.
- **Test Scenarios:** each affected template renders via `execute-template`; template balance intact (equal `if`/`end`); shellcheck clean on rendered output.
- **Verification:** render-check across all `.sh.tmpl`; grep confirms no `chezmoi.os "windows"` gate remains in `.sh.tmpl`.

### U3. Remove Windows data, facts mirror, and target-state gates

- **Goal:** drop Windows from data authorities and target-state gates.
- **Files:** `.chezmoidata/visualstudio.yaml` (delete); `.chezmoidata/packages.yaml` (remove every capability's `windows:` stanza and `architectures.windows`); `.chezmoidata/facts.yaml` (drop `windows` from the `os` fact `values` and the facts-sh mirror); `.chezmoiignore` (Windows blocks: AppData, `.ps1`, `30-windows`, `60-build mxm4-haptic.ps1`); `.chezmoiremove` (Windows gates); `.chezmoidata/{agents,networking,vscodium,haptic}.yaml` apply-surface Windows fields/comments only (leave cross-platform os-lists that gate externals).
- **Patterns:** data-driven removal; keep linux/darwin; schemas must still validate.
- **Test Scenarios:** `packages-validate.tmpl` passes; `facts-validate.tmpl` passes; no `windows:` keys in `packages.yaml` capabilities; no `eq/ne .chezmoi.os "windows"` blocks in `.chezmoiignore`/`.chezmoiremove`.
- **Verification:** render-check; schema validation templates.

### U4. Update managed instructions and repo docs

- **Goal:** drop Windows-parity rules from managed instructions.
- **Files:** `AGENTS.md`; `.chezmoitemplates/agents-instructions.tmpl`; `.agents/skills/sync-omp-models/SKILL.md` (Windows render reference).
- **Patterns:** remove Windows clauses (haptic Task Scheduler, omp Windows deployment, facts Windows mirror, tmux Windows exclusion, POSIX/`.ps1` alignment); keep macOS/Linux; do not claim the release subsystem is purged.
- **Test Scenarios:** no Windows-parity rule remains in managed instruction files; docs read coherently.
- **Verification:** docs review; grep for residual Windows-parity rules.

### U5. Trim `ci.yml`

- **Goal:** remove Windows + spent + cutover jobs; simplify `omp-agent-integration`; repoint `delivery`.
- **Files:** `.github/workflows/ci.yml`; `.ci/test-omp-agent-reconcile.sh` (drop `.ps1` args).
- **Patterns:** delete jobs `mxm4-haptic-windows`, `native-windows-x64`, `ydotool-integration`, `garden-registry-relocation`, `secrets-cache-removal`, `kitty-provisioning`, `support-matrix`, `native-fedora-x64`, `native-macos-arm64`, `evaluator-gates`; shrink `figma-skills-native`/`rust-crate` matrix to `[ubuntu-latest, macos-26]`; in `omp-agent-integration` remove the Windows `.ps1` force-render block and the `.ps1` args to `test-omp-agent-reconcile.sh`; repoint `delivery` `needs:` to `[omp-agent-integration, ts-workspace, figma-skills-native, rust-crate, tmux-kitty-passthrough, compound-engineering-overlays]`.
- **Test Scenarios:** `actionlint` passes (if installed); no removed job is referenced by any surviving `needs:`; CI green.
- **Verification:** actionlint; CI run. Governs R5, R6, R7, R9, R11.

### U6. Trim `render-dotfiles.yml`

- **Goal:** remove Windows render/lint jobs; repoint `gate`.
- **Files:** `.github/workflows/render-dotfiles.yml`.
- **Patterns:** delete `apply-windows` and `lint-powershell`; drop them from the `gate` aggregate `needs:`.
- **Test Scenarios:** `actionlint` passes; `gate` references only surviving jobs; CI green.
- **Verification:** actionlint; CI run. Governs R5, R11.

### U7. Remove cutover apparatus, `device-smoke.yml`, and retired/Windows `.ci` scripts

- **Goal:** delete the forward-looking cutover machinery, the device-smoke workflow, and orphaned test scripts.
- **Files:** `.github/workflows/device-smoke.yml` (delete); `.ci/{cutover-gates.json,cutover-gates.schema.json,device-evidence.schema.json,support-matrix.json,support-matrix.schema.json,evaluate-cutover-gates.mjs,validate-device-evidence.mjs,test-cutover-gates.sh}` (delete); `.ci/fixtures/cutover-gates/` (delete tree); `.ci/device-evidence/` (delete); retired-guard scripts `.ci/{test-garden-registry-relocation,test-secrets-cache-removal,test-ydotool-integration,test-kitty-provisioning}.sh` (delete); Windows/orphaned `.ci` scripts — delete only after confirming no surviving job references them (candidates: `collect-device-evidence.{ps1,sh}`, `test-device-collectors.{ps1,sh}`, `test-figma-skills-{reconcile,stage}.ps1`, `test-install-prerequisites-op-auth.ps1`, `test-mxm4-haptic-provision.ps1`, `test-omp-agent-reconcile.ps1`, `test-wifi-import-windows.ps1`, `test-visualstudio-provisioner.sh`, `test-windows-garden-reconcile.sh`, `test-windows-trust.sh`).
- **Patterns:** per KTD3, grep `.github/workflows/` for each candidate's callers before deleting; keep any script a surviving job still references.
- **Test Scenarios:** no surviving CI job references a deleted script; `.ci/fixtures/cutover-gates/` and `device-smoke.yml` gone; CI green.
- **Verification:** grep references in `.github/workflows/`; CI run. Governs R6, R7.

## Verification Contract

| Gate | Command / method | Applicability |
---|---|---|
| Local render-check | scratch dir + `op` stub + `chezmoi --source "$PWD" execute-template` on every changed `.tmpl`; compare rendered scripts as text; never deploy live `$HOME` | All template-touching units (U1–U4) |
| Workflow lint | `actionlint .github/workflows/ci.yml .github/workflows/render-dotfiles.yml` (if installed) | U5, U6 |
| Tree hygiene | `git diff --check`, `git status` | All units |
| Primary merge gate | CI green — `render-dotfiles.yml` (apply/render-internals/apply-macos/shellcheck/gate) and `ci.yml` (omp-agent-integration/ts-workspace/figma-skills-native/rust-crate/tmux-kitty-passthrough/compound-engineering-overlays) | All units |

Side-effect disclosure: this PR removes many CI jobs; the first push shows the trimmed matrix. No network/service restarts occur in CI.

## Definition of Done

- No `.ps1`/`.ps1.tmpl` under `.chezmoiscripts/` or `dot_local/bin/`; `.install-prerequisites.ps1` gone; `20-windows`/`30-windows` dirs gone.
- No `chezmoi.os "windows"` gates in `.sh.tmpl`; template balance intact.
- `packages.yaml` has no `windows:` stanzas; `visualstudio.yaml` gone; `facts.yaml` `os` values are `[linux, darwin]`.
- `.chezmoiignore`/`.chezmoiremove` have no Windows gates.
- `AGENTS.md`, `agents-instructions.tmpl`, and the sync-omp-models SKILL carry no Windows-parity rules.
- `ci.yml` keeps only the 6 surviving jobs + repointed `delivery`; `render-dotfiles.yml` has no `apply-windows`/`lint-powershell` and a repointed `gate`.
- `device-smoke.yml`, the cutover `.ci` files/fixtures, and the 4 retired-guard scripts are gone; no surviving job references a deleted script.
- CI green on both workflows.
- Release-subsystem windows references (`externals` ternaries, `releases.json` keys) intentionally retained as a documented follow-up.
