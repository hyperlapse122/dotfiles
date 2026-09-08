---
title: Mirror the remote namespace verbatim in the ~/src layout - Plan
type: refactor
date: 2026-09-08
topic: src-full-path-mirroring
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Mirror the remote namespace verbatim in the ~/src layout - Plan

## Goal Capsule

- **Objective:** Every project path under `~/src` is derivable from its clone URL alone, so nobody — operator or agent — decides where a repository lives, and a declaration that breaks the rule cannot reach a host.
- **Means:** Redefine the layout as verbatim remote-namespace mirroring and enforce it at apply time with a shared checker (KD1, KD2, KTD1).
- **Authority hierarchy:** The R-IDs own what must be true after the change. `.chezmoitemplates/agents-instructions.tmpl` is the single owner of the layout rule text; the registry header, `src-audit`'s comment, and `STRATEGY.md` describe that rule and never redefine it. KTDs own implementation mechanism within those R constraints. `AGENTS.md` owns the standing repository rules, including the prohibition on committing plaintext registry content.
- **Open blockers:** None.
- **Stop conditions:** Stop and report if the registry round trip in U2 fails any of its verifications, if `garden ls` stops emitting a per-tree `origin:` line (U3's input contract), or if a tree's remote URL cannot be reduced to a path by the R1 derivation.
- **Execution profile:** A declaration rewrite plus one new shared shell helper, one new CI gate, and one apply-time gate. No repository is cloned, moved, or deleted by the branch. CI proves the checker's logic against fixtures, never the real registry — see the Verification Contract.
- **Tail ownership:** The pipeline owns commit, push, PR, and CI. The operator owns the `chezmoi apply` that provisions the new paths, and owns whatever cleanup the old paths need.

**Product Contract preservation:** unchanged. Planning resolved the three `Deferred to Planning` questions into KTD1–KTD5 and removed the now-answered Open Questions section; no requirement, scope boundary, or acceptance example was altered.

---

## Product Contract

### Summary

Replace the `~/src` layout rule with a mechanical one: the on-disk path is the clone URL's host followed by its full remote namespace, with no segment dropped, added, or renamed. Enforce the rule at `chezmoi apply` so a deviating manifest fails before it provisions anything.

### Problem Frame

The layout rule reads `~/src/<remote-host>/<group>/<project>/`, but the group segment is defined by human judgment: it is "normalized by mirroring an existing sibling," and where no sibling settles it the instruction is to ask. That judgment has to be re-applied every time a repository is added, and its results are not recorded anywhere the next person can check.

The results accumulated in the manifest as prose. Three comment blocks in the registry now explain when the `products` umbrella segment survives and when a product subgroup replaces it, and why one remote subgroup appears on disk under a different, human-chosen name. Twelve of twenty-three declared trees deviate from their remote namespace on that basis.

Nothing verifies any of it. `src-audit` derives its checks from the manifest and only states the layout shape in a comment, so a deviating path is indistinguishable from a correct one. The exceptions grew silently and will keep growing.

### Key Decisions

- KD1. **Paths mirror the remote namespace verbatim.** No umbrella segment is dropped, no remote name is replaced with a friendlier one. (session-settled: user-directed — chosen over keeping the current normalization and over dropping repo-less umbrella segments: an exception the rule cannot state is an exception that recurs.) Governs R1, R2, R3.
- KD2. **Enforcement runs at apply, with CI covering the checker against fixtures.** The registry is GPG-encrypted and CI holds no key, so CI cannot read real declarations. (session-settled: user-directed — chosen over a CI test reading the manifest and over a report-only `src-audit` classification: apply is the only point that sees plaintext, and it can refuse.) Governs R6, R7, R8.
- KD3. **No cutover work.** The rule change ships alone; existing checkouts and their orca/aoe registrations are left to a clean apply. (session-settled: user-directed — chosen over deleting and re-cloning the affected trees: the operator will apply from a clean state, so migration would be work with no target.) Governs R11.

### Requirements

**Path rule**

- R1. The on-disk path of a project under `~/src` is `<host>/<remote namespace path>`, taken from the clone URL with any `.git` suffix removed and every remaining path segment preserved in order and in the case the remote uses.
- R2. The rule admits no exception. There is no sibling-mirroring step, no umbrella-segment judgment, and no case in which an operator or agent is instructed to ask where a repository should live.
- R3. The mapping is reversible: the clone URL can be reconstructed from the path plus the remote's scheme, and the path can be reconstructed from the URL.

**Registry**

- R4. Every declared tree's `path` equals the value R1 derives from its `url`.
- R5. The manifest carries no prose describing a path exception. Its header describes the derivation rule and points at the instruction template as the rule's owner.

**Enforcement**

- R6. `chezmoi apply` fails when any declared tree's `path` deviates from the value R1 derives from its `url`, and the failure names each offending tree with its declared and derived paths.
- R7. The check runs before any tree is grown, so a deviating declaration never creates a directory.
- R8. A CI test exercises the checker against fixtures covering at least a conforming declaration, a deviating declaration, and a URL carrying a `.git` suffix. The test uses no real registry content and needs no decryption key.

**Rule text and documentation**

- R9. `.chezmoitemplates/agents-instructions.tmpl` states the R1 rule and carries no residual instruction to normalize against siblings or to ask when the group segment is unclear.
- R10. Every other place that describes the layout shape — `src-audit`'s header comment, the `STRATEGY.md` track description, and the manifest header — agrees with R1 and does not restate the rule in full (per R9's ownership).

**Boundary**

- R11. The change touches declarations and rule text only. It moves, deletes, or re-registers nothing on disk.

#### Trees affected by R4

Twelve of twenty-three declared trees deviate today. The remaining eleven — `signet`, `vetbot-ai`, `works`, `dimse-bridge`, `knowledge-base`, `workspace`, `fleet`, and the four `github.com` trees — already satisfy R1.

| Tree | Declared path | Path derived from `url` |
|---|---|---|
| `examvue-apps` | `git.jpi.app/examvue-duo/examvue-apps` | `git.jpi.app/products/examvue-duo/examvue-apps` |
| `ExamVueDuo_AI` | `git.jpi.app/examvue-duo/ExamVueDuo_AI` | `git.jpi.app/products/examvue-duo/ExamVueDuo_AI` |
| `ExamVueDuo_WAS` | `git.jpi.app/examvue-duo/ExamVueDuo_WAS` | `git.jpi.app/products/examvue-duo/ExamVueDuo_WAS` |
| `telerad-openapi` | `git.jpi.app/examvue-365-flow/telerad-openapi` | `git.jpi.app/products/365flow/telerad-openapi` |
| `telerad-frontend` | `git.jpi.app/examvue-365-flow/telerad-frontend` | `git.jpi.app/products/365flow/telerad-frontend` |
| `telerad-payment` | `git.jpi.app/examvue-365-flow/telerad-payment` | `git.jpi.app/products/365flow/telerad-payment` |
| `landing-frontend` | `git.jpi.app/examvue-365-flow/landing-frontend` | `git.jpi.app/products/365flow/landing-frontend` |
| `shadcn-registry` | `git.jpi.app/examvue-365-flow/shadcn-registry` | `git.jpi.app/products/365flow/shadcn-registry` |
| `pacs-dicom` | `git.jpi.app/examvue-365-flow/pacs-dicom` | `git.jpi.app/products/365flow/pacs-dicom` |
| `pacs-backend` | `git.jpi.app/examvue-365-flow/pacs-backend` | `git.jpi.app/products/365flow/pacs-backend` |
| `pacs-scp` | `git.jpi.app/examvue-365-flow/pacs-scp` | `git.jpi.app/products/365flow/pacs-scp` |
| `pacs-frontend` | `git.jpi.app/examvue-365-flow/pacs-frontend` | `git.jpi.app/products/365flow/pacs-frontend` |

### Acceptance Examples

- AE1. Conforming manifest
  - **Covers R4, R6, R7.**
  - **Given:** every declared tree's `path` matches its derived value.
  - **When:** the operator runs `chezmoi apply`.
  - **Then:** the check passes silently and grow proceeds as it does today.
- AE2. Deviating declaration
  - **Covers R6, R7.**
  - **Given:** a tree declares `git.jpi.app/365flow/pacs-scp` against a `products/365flow/pacs-scp` remote.
  - **When:** the operator runs `chezmoi apply`.
  - **Then:** the apply fails naming that tree, its declared path, and its derived path, and no directory for it is created.
- AE3. New repository added
  - **Covers R1, R2.**
  - **Given:** an operator adds a repository whose remote sits under a group with no existing sibling on disk.
  - **When:** they write the declaration.
  - **Then:** the path follows from the URL with no decision to make, and no instruction anywhere tells them to ask.

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This plan owns the `~/src` layout rule and its enforcement. It was separated from a broader request that also asked to replace aoe with orca as the agentic workflow orchestrator. The breakdown below is the current understanding, not a committed roadmap.

- Replace aoe with orca as worktree and session owner
  - Can proceed independently of this plan. Neither change needs the other to land first.
  - Shares the same instruction section (`.chezmoitemplates/agents-instructions.tmpl`, "Repository layout and garden ownership") and the same registry bootstrap commands, so landing both means editing the same text twice.
  - Still to decide: whether orca's project and repo registration replaces `garden grow` and `src-audit`, or sits alongside them.
- Reconcile existing checkouts and registrations with whatever layout and orchestrator result
  - Depends on both changes above.
  - Still to decide: whether it is operator work on a clean rebuild or a declared step.

### Scope Boundaries

- Replacing aoe with orca as the worktree and session orchestrator. That is a separate change against the same instruction section; this plan leaves every aoe reference intact.
- Moving, deleting, or re-cloning the twelve affected checkouts, and re-registering them with orca or aoe (KD3).
- The garden tree-name convention (project leaf, `<group>-<project>` on collision). Names are independent of paths and no collision exists today.
- Worktree location. `~/orca/workspaces/` and `~/.local/share/worktrees/` are untouched; this plan governs primary checkouts only.

### Dependencies / Assumptions

- The aoe session `group` is derived from each tree's path relative to `${HOME}/src`, so it follows R4 automatically and needs no separate change. Verified against the `aoe-session` command in the deployed registry.
- `src-audit` performs no path-shape validation today — it resolves paths from the manifest and checks only that each is a valid git work tree — so R10 is a comment change there, not a behavior change.
- Every declared `url` is currently an `https` URL. R1 must still be stated in a way that holds for `ssh` remotes, since the instruction template documents the `git@<host>:<namespace>/<project>.git` form.
- The operator applies from a clean state. Applying on this host before that state is reached will clone the twelve affected trees to their new paths and leave the old directories in place, giving the same repository two locations.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The checker is one shared POSIX sh helper that reads a `name<TAB>declared-path<TAB>url` stream on stdin.** It parses no YAML and calls no external tool, so the same file serves the apply gate and a CI fixture test with no shared dependency between them. Implements KD2. Governs R6, R7, R8.
- KTD2. **The helper lives in `.chezmoitemplates/` as plain shell, not a template.** `.chezmoitemplates/` is the only directory `includeTemplate` can read, and a plain `.sh` file there can also be executed directly by a CI test. This mirrors `.chezmoitemplates/capability-cache-identity.sh`, which `.install-prerequisites.sh` sources, `capabilities.tmpl` embeds as raw bytes through `joinPath`, and `.ci/test-capability-cache.sh` drives directly.
- KTD3. **The apply-time front end builds the stream from one `garden ls --all --no-commands --no-gardens --no-groups -v 2>&1` call that replaces the completeness gate's existing call.** This call deliberately drops `--no-remotes`, which the current completeness call passes and which suppresses every `origin:` line. It emits a `# <name> [<branch>] <path>` or `#- <name> <path>` line per tree on stderr and an indented `origin: <url>` line on stdout, so the `2>&1` merge yields both fields and the header lines still feed the completeness check. Reusing `garden` keeps the gate free of a YAML parser on the apply path, where PyYAML is not a declared package.
- KTD4. **The front end reduces each listed path to its form relative to `garden.root` before comparison.** `garden ls` prints resolved absolute paths (`/home/h82/src/git.jpi.app/...`) while the registry declares paths relative to `${HOME}/src`, which is also the form R1 derives; comparing the two raw forms would report every tree as a deviation. A tree whose resolved path is not under the root is itself reported as a deviation rather than silently compared.
- KTD5. **The CI fixture test runs in the `repo-meta` job.** That job runs pure-shell repository gates with no chezmoi render and no `garden`; `.ci/test-ci-wiring.sh` already records that no runner provisions `garden`, which is why the helper's input contract is a plain stream rather than a registry file.

**Derivation rules (owned by R1, stated here as mechanism).** From a clone URL the helper produces `<host>/<namespace path>` by: dropping the scheme and any `user@` userinfo; taking the authority up to the first `/` or, for the `git@host:path` form, up to the first `:`; dropping a `:port` suffix from that authority; taking the remainder as the namespace path; stripping a leading `/` and a single trailing `.git`; and collapsing no other segment.

### High-Level Technical Design

```mermaid
flowchart TB
  H["`.chezmoitemplates/`<br/>garden-path-mirror-check.sh<br/>(one derivation, one comparison)"]
  R["`.chezmoiscripts/90-src/`<br/>reconcile-garden (rendered)"]
  G["garden ls --all -v"]
  T["`.ci/`<br/>test-garden-path-mirror-check.sh"]
  F["synthetic name/path/url fixtures"]
  A{"deviation?"}

  H -->|includeTemplate| R
  G -->|"name TAB path TAB url stream"| R
  R --> A
  A -->|yes| X["fail the apply, name each tree,<br/>grow never runs"]
  A -->|no| P["garden grow '*'"]
  H -->|executed directly| T
  F --> T
```

### Assumptions

- `garden ls -v` keeps emitting one `origin:` line per declared tree. The reconcile already depends on the same command's path field, so this widens an existing dependency rather than adding one. A tree with no `origin` remote is a malformed declaration and the helper reports it as such.
- `includeTemplate` renders the helper as a Go template, so the shell file must contain no `{{` sequence. The alternative already used by `capabilities.tmpl` — reading the file's raw bytes through `joinPath .chezmoi.sourceDir ".chezmoitemplates"` — is available if that ever becomes a constraint.
- The registry's `url` values remain the authority for derivation. The helper never consults a checkout's live git remote, so a hand-edited `.git/config` on a host cannot mask a bad declaration.

### Sequencing

U1 → U3 and U2 → U3. U2 lands before U3 so the enforcement gate never arrives against a registry that violates it. U4 is independent of the other three and may land in any position.

---

## Implementation Units

### U1. Shared path-mirroring checker and its fixture test

- **Goal:** One helper turns a declaration stream into a pass/fail verdict with a named reason per offending tree, and CI proves it rejects what it must reject.
- **Requirements:** R1, R3, R6, R8.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/garden-path-mirror-check.sh` (new), `.ci/test-garden-path-mirror-check.sh` (new), `.github/workflows/ci.yml` (`repo-meta` job step).
- **Approach:**
  1. The helper reads `name<TAB>declared-path<TAB>url` records from stdin, one per line.
  2. It derives the expected path per the KTD1 derivation rules.
  3. It prints one line per deviation naming the tree, its declared path, and its derived path, and exits non-zero when any deviation or malformed record was seen.
  4. Keep it POSIX sh with no external commands beyond shell builtins and `printf`, so it runs identically under the apply shell and a CI runner.
  5. The test drives the helper directly with synthetic stdin streams, asserting both exit status and that a rejection names the offending tree.
  6. Add the test to the `repo-meta` job's existing gate list so `.ci/test-ci-wiring.sh` sees it wired.
- **Patterns to follow:** `.chezmoitemplates/capability-cache-identity.sh` for the shared plain-shell file and its header-stated contract; `.ci/test-check-external-checksum-coverage.sh` for the gate-plus-test-of-the-gate shape, its `fail`/`pass` helpers, and its `XDG_RUNTIME_DIR`-rooted scratch directory.
- **Test scenarios:**
  - Covers AE1. A stream whose every record already matches its derived path exits zero and prints no deviation.
  - Covers AE2. A record declaring `git.jpi.app/365flow/pacs-scp` against `https://git.jpi.app/products/365flow/pacs-scp.git` exits non-zero and names that tree with both paths.
  - A `url` ending in `.git` derives the same path as the identical `url` without the suffix.
  - An `ssh` remote in the `git@host:namespace/project.git` form derives `host/namespace/project`.
  - A URL carrying `user@` userinfo and a `:port` suffix derives the same path as the bare-host form.
  - A record whose `url` field is empty is reported as malformed and exits non-zero.
  - Multiple deviations in one stream are all reported, not just the first.
  - Covers R3. A path produced by the derivation, recombined with its remote's scheme, reconstructs the original `url` for each URL form exercised above.
  - A path differing from its derived value only in segment case is reported as a deviation.
- **Verification:** `.ci/test-garden-path-mirror-check.sh` passes locally, and `.ci/test-ci-wiring.sh` reports the new script as wired.

### U2. Rewrite the deviating registry declarations

- **Goal:** Every declared tree satisfies R4, and the manifest's exception prose is gone.
- **Requirements:** R4, R5, R10.
- **Dependencies:** none.
- **Files:** `dot_config/garden/encrypted_readonly_garden.yaml.asc`.
- **Approach:**
  1. Decrypt the registry to a scratch file under `$XDG_RUNTIME_DIR`, never into the working tree.
  2. Rewrite the twelve `path` values named in the Product Contract's affected-trees table, leaving every `url`, tree name, template, and command untouched.
  3. Delete the three exception comment blocks (the `products` umbrella rule, the `365flow` rename note, and the top-level-group note) and rewrite the header's layout description per R10, pointing at `.chezmoitemplates/agents-instructions.tmpl` as the rule's owner.
  4. Re-encrypt to a second scratch file, then verify the round trip before overwriting the source: decrypt the new ciphertext again, confirm it parses, and confirm the tree count and the recipient key-id set are unchanged.
  5. Move the verified ciphertext over the source. Never commit plaintext.
- **Execution note:** This is the one irreversible step in the branch — the registry is its own only copy. Complete every verification in step 4 before the move in step 5.
- **Patterns to follow:** The non-interactive decrypt/encrypt round trip documented in full in the deployed registry's own header; `AGENTS.md` carries only the `chezmoi edit` wrapper and the never-commit-plaintext rule.
- **Test scenarios:**
  - The re-decrypted registry parses as YAML and declares twenty-three trees.
  - Every tree's `path` equals the value derived from its `url` by the U1 helper.
  - No `url`, tree name, `templates` value, or `commands` block differs from the pre-edit registry.
  - The recipient key-id set of the new ciphertext matches the old one.
- **Verification:** A decrypt of the committed source parses, declares twenty-three trees, and feeds the U1 helper a stream with zero deviations.

### U3. Enforce the rule at apply

- **Goal:** A deviating declaration fails `chezmoi apply` before any tree is grown.
- **Requirements:** R6, R7.
- **Dependencies:** U1, U2.
- **Files:** `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl`.
- **Approach:**
  1. Inline the U1 helper with `includeTemplate`, alongside the script's existing prerequisite checks.
  2. Build the `name<TAB>path<TAB>url` stream from one `garden ls --all --no-commands --no-gardens --no-groups -v 2>&1` call, pairing each `# <name> … <path>` or `#- <name> <path>` header with the indented `origin:` line that follows it. This single call replaces the completeness gate's existing one and drops its `--no-remotes` flag (KTD3); its header lines still feed the existing extraction. Reduce each header's absolute path to its form relative to `garden.root` before emitting the record (KTD4), and skip garden's synthesized `.` root line as the completeness loop already does.
  3. Run the check between the prerequisite block and the `garden grow '*'` call, so a deviation exits before grow (R7).
  4. Capture `garden ls`'s own exit status first, as the existing completeness gate does, so a crash fails the apply instead of passing vacuously on empty output.
  5. Extend the script's header comment to name the new gate and why it lives here rather than in CI.
- **Patterns to follow:** The completeness gate later in the same file — the `2>&1` merge, the `sed -n -e 's/^# //p' -e 's/^#- //p'` extraction, the heredoc loop that keeps `rc` in the current shell, and the hard-fail message shape.
- **Execution note:** Verify the gate in isolation. Never run the reconcile script end to end on a developer host — it calls `garden grow '*'` and `garden cmd '*' setup-upstream aoe-session`, which would clone the twelve retargeted trees and re-register sessions, breaking R11.
- **Test scenarios:**
  - Covers AE1. Running only the gate section against a scratch copy of the deployed registry under `$XDG_RUNTIME_DIR` exits zero and prints no deviation.
  - Covers AE2. Against that scratch copy with one `path` mutated, the gate exits non-zero and names that tree with both paths.
  - A `garden ls` failure exits non-zero rather than passing on empty output.
  - The gate appears before the `garden grow '*'` call, verified by reading the rendered script rather than executing it.
  - Absolute paths from `garden ls` are reduced to root-relative form, so a conforming registry produces zero deviations.
- **Verification:** `chezmoi execute-template` renders the script, `bash -n` parses it, the gate-before-grow ordering is visible in the rendered text, and the two scratch-registry cases produce the stated exit statuses. No `garden grow` or `garden cmd` runs.

### U4. Rewrite the layout rule and align its descriptions

- **Goal:** The rule text states R1 with no residual judgment step, and every other description agrees with it.
- **Requirements:** R2, R9, R10.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`, `dot_local/share/chezmoi-command-sources/executable_src-audit`, `STRATEGY.md`.
- **Approach:**
  1. Rewrite the "Repository layout and garden ownership" opening paragraph to state R1, removing the sibling-mirroring normalization, the group-less-remote carve-out, and the instruction to ask.
  1b. Update the two later restatements in the same file to the `<host>/<remote namespace path>` shape: the primary-checkout paragraph's `~/src/<remote-host>/<group>/<project>/` and the aoe-group example `github.com/<group>/<project>`. Both understate a multi-segment namespace such as `products/365flow/pacs-scp`, so leaving them reinstates the old shape inside the rule's own owner.
  2. Leave every aoe reference in that section intact — the orchestrator change is out of scope (Scope Boundaries).
  3. Update `src-audit`'s header comment and the `STRATEGY.md` "Project garden and worktrees" track wording to the new shape, without restating the rule in full.
- **Patterns to follow:** The instruction template's existing RFC 2119 phrasing and its one-owner discipline — other sites describe, the template defines.
- **Test scenarios:**
  - `.ci/test-agent-instructions.sh` passes against the rewritten template.
  - The template renders to each managed harness's instruction file with no unresolved template error.
  - No file outside `.chezmoitemplates/agents-instructions.tmpl` states the derivation rule in full.
  - The template contains no remaining `<group>/<project>` restatement that understates a multi-segment namespace.
- **Verification:** The rendered instruction files carry the new rule, a search for "mirroring an existing sibling" and "ask rather than guess" returns nothing outside `docs/`, and no `<group>/<project>` two-segment shape remains in the template.

---

## Verification Contract

| Gate | Command | Applies to | Done signal |
|---|---|---|---|
| Checker logic | `.ci/test-garden-path-mirror-check.sh` | U1 | Every fixture case passes |
| CI wiring | `.ci/test-ci-wiring.sh` | U1 | The new gate is reported as wired |
| Instruction render | `.ci/test-agent-instructions.sh` | U4 | Passes against the rewritten template |
| Script syntax | `bash -n` on the rendered reconcile script | U3 | Parses |
| Registry round trip | Decrypt the committed source, parse it, count trees, compare recipients | U2 | Twenty-three trees, recipients unchanged |
| Rule conformance | Feed the decrypted registry through the U1 helper | U2, U3 | Zero deviations |
| Full suite | The `repo-meta` job's gate list plus the rest of `.github/workflows/ci.yml` | all | Green |

CI never reads the real registry (KD2). The registry round trip and rule conformance gates are local verifications the implementer runs before commit.

---

## Definition of Done

**Global**

- Every R-ID above is satisfied, and the twelve declarations in the affected-trees table carry their derived paths.
- The three exception comment blocks are gone from the registry and no replacement exception prose was introduced.
- `chezmoi apply` fails on a deviating declaration and does so before `garden grow` runs.
- No plaintext registry content is committed, and no scratch decryption artifact remains in the working tree.
- The branch moves, deletes, or re-registers nothing on disk (R11).
- No abandoned or experimental code remains in the diff.
- Every gate in the Verification Contract passes.

**Per unit**

- U1: the helper reports as its header comment states, the fixture test covers every scenario listed, and `.ci/test-ci-wiring.sh` sees it wired.
- U2: the committed ciphertext decrypts to twenty-three conforming trees with unchanged recipients.
- U3: the rendered reconcile script runs the gate before grow and hard-fails on deviation.
- U4: the instruction template owns the rule and the three describing sites agree with it.

---

## Sources / Research

- `.chezmoitemplates/agents-instructions.tmpl:33` — the current rule, including the sibling-mirroring normalization and the instruction to ask.
- `.chezmoitemplates/agents-instructions.tmpl:45` — states that the aoe session group is the project's full path under `~/src` including the host segment, which is why R4 needs no separate aoe change.
- `.chezmoitemplates/capability-cache-identity.sh` — the precedent for a plain shell file shared out of `.chezmoitemplates/` (KTD2).
- `.chezmoiscripts/90-src/run_onchange_after_reconcile-garden.sh.tmpl` — the apply-time reconcile, its `garden ls` parse, and the hard-fail completeness gate U3 extends.
- `.ci/check-external-checksum-coverage.sh` and `.ci/test-check-external-checksum-coverage.sh` — the gate-plus-test-of-the-gate pattern U1 follows.
- `.ci/test-ci-wiring.sh:57` — records that no CI runner provisions `garden`, which fixes the helper's input contract (KTD1, KTD5).
- `.github/workflows/ci.yml:237-259` — the `repo-meta` job U1 joins.
- `dot_config/garden/encrypted_readonly_garden.yaml.asc` header — documents the decrypt/re-encrypt round trip U2 follows in full; `AGENTS.md` carries only the `chezmoi edit` wrapper and the never-commit-plaintext rule.
- `.github/workflows/render-dotfiles.yml:208,709` — both apply legs run `chezmoi apply --exclude=scripts,encrypted`, so every encrypted target is excluded from the render and CI never sees a declaration.
- `dot_local/share/chezmoi-command-sources/executable_src-audit` — the read-only drift report; its header comment states the layout shape it does not verify.
