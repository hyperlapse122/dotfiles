---
title: "refactor: hoist distro-independent flatpaks and dotnetTools to shared linux scope"
date: 2026-07-22
type: refactor
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# refactor: hoist distro-independent flatpaks and dotnetTools to shared linux scope

## Summary

`flatpaks` and `dotnetTools` in `.chezmoidata/packages.yaml` are duplicated under both `packages.linux.fedora` and `packages.linux.ubuntu`, even though neither list depends on the distro — Flatpak apps come from Flathub and .NET global tools install via `dotnet tool install -g`, both distro-agnostic delivery mechanisms. Per the user directive ("these are shared regardless of distro; they don't need per-distro management"), this refactor removes the per-distro duplication by hoisting a single shared copy up to `packages.linux.flatpaks` / `packages.linux.dotnetTools`, and repoints the two installer templates at the new path. The two lists are not identical today: `flatpaks` already matches on both distros, but `dotnetTools` differs — `csharp-ls` is currently listed only under Fedora. Realizing "shared" as one list means the shared `dotnetTools` is the **union** (superset), so **Ubuntu newly installs `csharp-ls`** — a deliberate behavior change flowing from the shared-scope directive, called out explicitly in KTD-2.

## Problem Frame

- **In scope:** the `flatpaks` and `dotnetTools` keys only.
- **Current state:** identical `flatpaks` lists (`com.discordapp.Discord`, `org.telegram.desktop`) under both distros; `dotnetTools` lists that differ by one entry (`csharp-ls` present under Fedora, absent under Ubuntu — added by the deliberate per-distro commit `6094012` "add lsp plugins", which scoped `clangd`→Ubuntu and `clang-tools-extra`+`csharp-ls`→Fedora). Two installer templates (`run_onchange_before_fedora.sh.tmpl`, `run_onchange_before_ubuntu.sh.tmpl`) read these keys via the per-distro path.
- **Why change:** the user directs that these two lists be managed as distro-independent shared sets. The per-distro nesting misrepresents the data (both lists are delivered by distro-agnostic mechanisms), and keeping two copies invites future divergence.
- **Single-source-of-truth constraint (AGENTS.md):** edit the data file and the template consumers; the rendered installer is generated, never hand-edited. `flatpaks` and `dotnetTools` become one shared list each.

## Requirements

- **R1** — `flatpaks` and `dotnetTools` each appear exactly once in `packages.yaml`, at a distro-independent location under `packages.linux`, and no longer under `fedora:` or `ubuntu:`.
- **R2** — The consolidated `dotnetTools` is the union of the two prior lists: `git-credential-manager`, `powershell`, `csharp-ls`. The consolidated `flatpaks` is the (identical) shared list: `com.discordapp.Discord`, `org.telegram.desktop`.
- **R3** — Both installer templates render byte-identical Bash arrays to today's output **except** the Ubuntu `dotnet_tools` array, which gains `csharp-ls` (the intended drift fix). Array *ordering and quoting* stay as the templates already produce them.
- **R4** — No other `packages.yaml` key, gate, or installer logic changes. `git diff --check` is clean and the diff is limited to the three files below.
- **R5** — The file's documentation style is preserved: the new shared keys carry an explanatory comment consistent with the surrounding verbose-comment convention, and the moved keys' original comments travel with them.

## Assumptions

Pipeline-mode inferred bets (recorded rather than confirmed interactively):

- **A1 — placement.** The shared keys are hoisted to `packages.linux.flatpaks` and `packages.linux.dotnetTools` as direct siblings of `fedora:` / `ubuntu:`, **not** wrapped in a new `packages.linux.shared:` sub-map. Rationale in KTD-1. If the user prefers an explicit `shared:` namespace, only the YAML placement and the two template path strings change — units are otherwise identical.
- **A2 — union semantics.** "Shared regardless of distro" means the drift is unintended, so the merged `dotnetTools` is the **union** (Ubuntu gains `csharp-ls`), not the intersection. This is a deliberate, called-out behavior change (KTD-2), not silent scope creep.
- **A3 — the user's `flatpacks` spelling** in the request is a typo for the actual key `flatpaks`; the real key name is unchanged.

## Key Technical Decisions

### KTD-1 — Hoist to direct siblings under `packages.linux`, not a `shared:` sub-map

Place the two lists at `packages.linux.flatpaks` and `packages.linux.dotnetTools`, alongside the `fedora:` and `ubuntu:` distro maps.

- **Why this works safely:** every consumer reads `.packages.linux` by explicit, guarded distro name and nothing iterates its *key set*. There are three consumers, all inert to new siblings: (1) `run_onchange_before_fedora.sh.tmpl` — `.packages.linux.fedora.<key>`; (2) `run_onchange_before_ubuntu.sh.tmpl` — `.packages.linux.ubuntu.<key>`; (3) `dot_local/bin/executable_host-facts.tmpl` — two `index .packages.linux <distro>` lookups, one inside a hardcoded `range (list "fedora" "ubuntu")`, the other guarded to those two names. Because no reader enumerates the map's keys, adding two list-typed siblings to a map that otherwise holds distro sub-maps is inert to all three. (Earlier drafts of this plan under-counted the consumers as "only the two installers"; the feasibility pass corrected it — the conclusion is unchanged, the enumeration is now complete.)
- **Why not `shared:`:** an extra nesting level buys no safety here and reads as ceremony; the direct sibling path is the most literal expression of "belongs to linux, not to a distro." (A `shared:` variant remains a one-line pivot if desired — see A1.)

### KTD-2 — Consolidated `dotnetTools` is the union; Ubuntu gains `csharp-ls`

The shared list is `[git-credential-manager, powershell, csharp-ls]` — the **union** of the two current lists. **Behavior change:** the next Ubuntu apply installs `csharp-ls`.

Grounding (stated honestly rather than as an unverified "accident"): `csharp-ls` is a `dotnet tool install -g` target with no distro dependency, and git history shows its Fedora-only placement was a *deliberate* per-distro scoping choice (commit `6094012`), not proven accidental drift. The union is therefore a **forward decision** endorsed by the user's explicit "shared regardless of distro" directive, not the correction of a demonstrated mistake. Under that directive the union is the right merge: it is a superset, so no host loses a currently-working tool. The alternatives are both worse under the directive — intersection would *remove* `csharp-ls` from Fedora (contradicting "shared" by shrinking coverage), and keeping `dotnetTools` per-distro would ignore the directive outright. The one thing to keep loud (and surfaced back to the user) is the concrete effect: Ubuntu gains a C# language server it does not install today; if the user intended `csharp-ls` to stay Fedora-only, that contradicts the shared-scope framing and they can veto. `flatpaks` is already identical on both distros, so it carries no behavior change.

### KTD-3 — Onchange retrigger is automatic and correct

Both installers are `run_onchange_before_` scripts whose trigger is their own rendered content (no separate `fingerprint.tmpl`). After the refactor: the Fedora rendered script is byte-identical (its `flatpaks`/`dotnet_tools` arrays are unchanged), so it does not re-run — correct, nothing to do on Fedora. The Ubuntu rendered script's `dotnet_tools` array changes (adds `csharp-ls`), so it re-runs and installs the tool — correct. No manual fingerprint edit is needed.

## Implementation Units

### U1. Restructure `packages.yaml` — hoist shared keys, merge `dotnetTools`

**Goal:** Establish the single shared source for both lists and remove the per-distro copies.

**Requirements:** R1, R2, R5; realizes KTD-1, KTD-2.

**Dependencies:** none.

**Files:**
- `.chezmoidata/packages.yaml` (modify)

**Approach:**
- Add `flatpaks:` and `dotnetTools:` at 4-space indent directly under `linux:`, placed **before** `fedora:` so the cross-distro lists read first. Give each a short comment in the file's existing verbose style noting they are distro-independent (Flathub / `dotnet tool install -g`) and deliberately not nested per-distro. Carry over the per-item trailing comments from the original entries (e.g. `git-credential-manager  # cross-platform Git credential helper (GCM)`).
- `flatpaks`: `com.discordapp.Discord`, `org.telegram.desktop`.
- `dotnetTools`: `git-credential-manager`, `powershell`, `csharp-ls` (union; `csharp-ls` retained from the Fedora list). **Preserve exactly this order** — it is Fedora's current order, so the Fedora `dotnet_tools` array renders byte-identical and its installer does not re-run (KTD-3).
- Delete the `flatpaks:` and `dotnetTools:` blocks (keys, values, and their preceding comment lines) from both `packages.linux.fedora` and `packages.linux.ubuntu`.

**Patterns to follow:** the surrounding comment density and the `# ...` per-item annotation style already used throughout `packages.yaml`.

**Execution note:** data-only change; proof is a successful template render (U3), not a unit test.

**Test scenarios:** `Test expectation: none — pure data restructure; behavior is verified by the render/shellcheck gates in U3.`

**Verification:** `flatpaks`/`dotnetTools` appear once each under `packages.linux`, absent under both distros; file still parses (confirmed transitively when U3 renders).

### U2. Repoint both installer templates at the shared path

**Goal:** Make the two consumers read the hoisted keys.

**Requirements:** R3, R4; realizes KTD-1.

**Dependencies:** U1.

**Files:**
- `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl` (modify)
- `.chezmoiscripts/40-linux-ubuntu/run_onchange_before_ubuntu.sh.tmpl` (modify)

**Approach:**
- Fedora: change `range .packages.linux.fedora.flatpaks` → `range .packages.linux.flatpaks` and `range .packages.linux.fedora.dotnetTools` → `range .packages.linux.dotnetTools`. Leave surrounding `flatpaks=(` / `dotnet_tools=(` array shells and whitespace exactly as-is.
- Ubuntu: the same two path edits against `.packages.linux.ubuntu.flatpaks` / `.dotnetTools`.
- Touch nothing else in either template — no gate logic, no other ranges.

**Patterns to follow:** the existing `{{ range ... -}}{{ . | quote }}{{ end -}}` array-rendering idiom already in each file (keep each template's own indentation — Fedora indents the loop body two spaces, Ubuntu does not).

**Execution note:** these are the four lines identified in research (`fedora` L134/L139, `ubuntu` L176/L181).

**Test scenarios:** `Test expectation: none — template path edits; correctness is proven by the rendered-output diff in U3.`

**Verification:** no remaining `.packages.linux.fedora.flatpaks` / `.fedora.dotnetTools` / `.ubuntu.flatpaks` / `.ubuntu.dotnetTools` references anywhere (grep is empty).

### U3. Verify rendered output and diff scope

**Goal:** Prove the refactor is behavior-preserving except the one intended Ubuntu addition, and scoped to three files.

**Requirements:** R3, R4.

**Dependencies:** U1, U2.

**Files:**
- none (verification only)

**Approach (isolated render per AGENTS.md, never live `$HOME`):**
- Render each installer through `chezmoi execute-template` using the op-stub scratch harness (`env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < <installer>`), for the current host distro; where the other distro's `{{ if eq ... }}` OS gate suppresses its body locally, capture that arm from CI's `render-dotfiles.yml` artifact and state that as the render blind spot.
- Also render the third `.packages.linux` consumer, `dot_local/bin/executable_host-facts.tmpl`, to confirm the new sibling keys leave it unchanged (KTD-1 asserts it is inert; prove it rather than only asserting it).
- Extract the rendered `flatpaks=( … )` and `dotnet_tools=( … )` arrays from both installers and confirm: Fedora both arrays unchanged vs. `main`; Ubuntu `flatpaks` unchanged and `dotnet_tools` gains exactly `csharp-ls`.
- Run `shellcheck` on the rendered scripts (matching the CI `ci.yml` shellcheck job) to confirm the arrays still lint.
- `git diff --check`; confirm `git status` lists only the three files; review the diff.

**Execution note:** smoke/render verification is the right proof for config+template work — there is no unit-test surface for chezmoi data.

**Test scenarios:**
- Fedora render: `flatpaks` = `com.discordapp.Discord`, `org.telegram.desktop`; `dotnet_tools` = `git-credential-manager`, `powershell`, `csharp-ls` — identical to pre-refactor Fedora output.
- Ubuntu render: `flatpaks` unchanged; `dotnet_tools` = `git-credential-manager`, `powershell`, `csharp-ls` (adds `csharp-ls`).
- `shellcheck` on both rendered scripts: exit 0.
- `git status`: exactly `.chezmoidata/packages.yaml` and the two installer templates modified.

**Verification:** all four scenarios pass; `git diff --check` clean.

## Verification Contract

- Both installers render without a template error under the isolated op-stub harness (`--source "$PWD"`, throwaway destination); the cross-distro arm is checked against the CI render artifact and that blind spot is stated.
- Rendered `flatpaks` arrays: unchanged on both distros. Rendered `dotnet_tools`: unchanged on Fedora, `+csharp-ls` on Ubuntu, and nothing else.
- `shellcheck` passes on both rendered scripts.
- `git grep` finds no surviving `.packages.linux.<distro>.flatpaks` / `.dotnetTools` reference.
- `dot_local/bin/executable_host-facts.tmpl` renders unchanged (third `.packages.linux` consumer; confirmed inert).
- `git diff --check` clean; change scoped to the three named files.
- After push: `render-dotfiles.yml` and `ci.yml` watched to terminal green.

## Scope Boundaries

**In scope:** hoisting `flatpaks` and `dotnetTools` to shared linux scope; the two template path edits; the `csharp-ls` union.

**Out of scope (true non-goals):**
- Any other `packages.yaml` key (`packages`, `corePackages`, `kdePackages`, gates, repos, direct RPM/DEB, etc.) — they are genuinely per-distro (different package names/mechanisms) and stay.
- Changing Flatpak/dotnet *install logic* in the installers.
- `AGENTS.md` / `README.md` prose — both mention "flatpaks"/"dotnet" only generically (not via the per-distro path), so they remain accurate; no edit needed.

### Deferred to Follow-Up Work

- None identified.

## Definition of Done

- R1–R5 satisfied.
- `packages.yaml` has one shared `flatpaks` and one shared `dotnetTools` under `packages.linux`; both removed from `fedora:` and `ubuntu:`.
- Both installers repointed; no stale per-distro path references remain.
- Verification Contract passes, including the intended Ubuntu `+csharp-ls` and no other rendered-output change.
- Diff limited to the three files; CI (`render-dotfiles.yml`, `ci.yml`) green.
