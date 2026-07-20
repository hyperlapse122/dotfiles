---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "refactor: compact agent instruction surfaces"
type: refactor
created: 2026-07-20
---

# refactor: compact agent instruction surfaces

## Goal Capsule

- **Objective:** Make the repository's two instruction sources materially shorter and easier for Claude Code to load while preserving every current binding rule, safety invariant, source-of-truth rule, and verification obligation.
- **Scope:** Modify only `AGENTS.md` and `dot_agents/readonly_AGENTS.md`. Do not edit wrapper templates, `CLAUDE.md`, deployed files, scripts, data, or policy behavior.
- **Canonical ownership:** `dot_agents/readonly_AGENTS.md` remains the common-agent core; root `AGENTS.md` remains the chezmoi-repository supplement and explicitly points to the common core instead of duplicating it.
- **Verification profile:** Documentation/configuration refactor; use static contract checks plus isolated chezmoi rendering through the repository's stub-`op` and throwaway-destination recipe. Never deploy to the live `$HOME`.
- **Stop condition:** If shortening a passage would remove a condition, exception, safety rationale needed to execute it, or a current source-of-truth relationship, retain the content in a compact form rather than deleting it.

---

## Problem Frame

`AGENTS.md` is approximately 1,430 lines and 155 KB, while the shared instruction source is approximately 148 lines and 21 KB. The root file mixes repository-specific chezmoi architecture with generic agent guardrails that already exist in `dot_agents/readonly_AGENTS.md`; both files also contain long historical explanations and repeated examples. This makes Claude Code approach its memory limit before work begins and makes load-bearing rules harder to locate.

The desired result is a two-layer instruction model:

1. The shared file states generic safety, Git, CI, tooling, and task-completion rules once, in compact normative language.
2. The root file states only this repository's source-state, chezmoi, host-platform, agent-configuration, secret-handling, verification, and delivery invariants, with short cross-references to the shared core where the rule is generic.

This is a documentation refactor, not a policy change. Existing behavior, exceptions, source-of-truth ownership, generated-target relationships, and verification requirements remain unchanged.

---

## Requirements

- **R1 — Exact file scope.** The implementation changes only `AGENTS.md` and `dot_agents/readonly_AGENTS.md`; no wrapper or generated target is edited.
- **R2 — Material reduction.** The combined source size is substantially lower than the baseline, with the largest reduction coming from removing duplicate prose, historical narrative, and redundant examples from `AGENTS.md`.
- **R3 — Shared-core preservation.** The shared file retains the complete current common guardrail set: routing, mirror policy, secrets, destructive-operation and Git-config prohibitions, project/worktree layout, branch ownership/naming, commit/rebase/issue scope, CI completion, Figma, long-running processes, scratch paths, Podman, browser automation, scripting, package-manager, mise, and GitLab CLI rules.
- **R4 — Repository-policy preservation.** The root file retains the current chezmoi source-state model; filename attributes; script ordering and `run_onchange_` policy; no-teardown rule; host-fact registry and gate grammar; shared partial contracts; system manifest; CLIProxyAPI security/runtime/rollback contract; agent skills/MCP/plugin/Pi contracts; isolated render verification; secret/keyring/age rules; data-driven source-of-truth map; toolchain split; OS/desktop parity; container fences; and repository-specific commit/branch/delivery rules.
- **R5 — No semantic weakening.** A removed paragraph must be either redundant with a retained canonical rule, historical/non-binding narrative, or an example safely replaced by a precise cross-reference. MUST/MUST NOT/SHOULD language, exceptions, failure modes, and safety boundaries remain explicit.
- **R6 — Executable cross-references.** Every cross-reference introduced by the refactor points to a section, file, or existing repository verification contract that an agent can access from the source checkout; no instruction depends on an uncommitted or external artifact.
- **R7 — Generated instruction parity.** The four wrapper templates remain bare one-line includes of `dot_agents/readonly_AGENTS.md`; after rendering, `~/.agents/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, and `~/.pi/agent/AGENTS.md` contain the same shared instruction content, with their existing source attributes and target modes unchanged.
- **R8 — Root operational completeness.** A reader following only the compact root file can locate the common core and execute repository work without losing any repository-specific invariant, source-of-truth location, secret-handling restriction, or verification obligation.
- **R9 — Verification safety.** All render checks use `--source "$PWD"`, an empty config, a stub `op`, and a throwaway destination under the permitted per-user scratch directory. No live `chezmoi apply`, real 1Password read, or generated-target edit is part of this work.

---

## Scope Boundaries

**In scope:** structural compression, deduplication, compact tables, precise local cross-references, removal of stale history/examples that do not bind behavior, and wording corrections needed to keep the two instruction sources internally consistent.

**Out of scope:** changing any policy decision; changing package/data/script/template behavior; changing source filename attributes or target modes; changing wrapper templates; changing `CLAUDE.md`; adding a linter, generated documentation, or a new verification script; updating deployed `$HOME`; rewriting historical plans; or resolving unrelated documentation drift.

### Deferred to Follow-Up Work

- A general instruction-lint or invariant-extraction tool. The current task uses review and render checks only; introducing tooling would widen scope.
- Any policy change discovered while comparing the two files. Preserve the current behavior and report the conflict rather than silently deciding a new rule.

---

## Key Technical Decisions

- **KTD1 — Edit both named sources.** *(session-settled: user-directed — chosen over compacting only one file: both surfaces contribute to loaded Claude Code context and the user explicitly named both.)* Modify `AGENTS.md` and `dot_agents/readonly_AGENTS.md` together so the shared/core split and its repository supplement remain coherent.
- **KTD2 — Optimize for compact precision, not exhaustive narrative.** *(session-settled: user-directed — chosen over retaining the current narrative form: Claude Code is near its memory limit.)* Prefer one normative sentence, a compact table, or a local cross-reference over repeated rationale and examples, but retain every condition required to execute safely.
- **KTD3 — Keep one canonical owner per rule.** Generic guardrails belong in `dot_agents/readonly_AGENTS.md`; repository-specific chezmoi contracts belong in `AGENTS.md`. The root file must state that the shared file is binding and is a supplement dependency, while project-specific text may add or override it only where explicitly named.
- **KTD4 — Replace history with present-tense contracts.** Remove migration chronology, deleted alternatives, issue backstory, and repeated “why this used to be different” prose unless it prevents a foreseeable unsafe action. Keep the current invariant and the shortest rationale needed to explain it.
- **KTD5 — Preserve operational detail through matrices.** Use tables for source-of-truth consumers, script groups, platform/container gates, agent surfaces, and verification commands. Keep security-sensitive CLIProxyAPI, secret, age, fact, and container behavior in explicit bullets rather than hiding it behind vague links.
- **KTD6 — Do not edit generated consumers.** The four wrapper templates already inline the shared source verbatim. Their one-line shape is an invariant and is verified, not “cleaned up.” `CLAUDE.md` remains the one-line `@AGENTS.md` mirror.
- **KTD7 — Render parity is the integration proof.** A successful isolated render of all four wrappers, byte-identical shared output across wrappers, and a source diff limited to the two requested files prove the refactor did not break the chezmoi instruction graph. Archive comparison, when run, expects only the five generated instruction targets to change.

---

## High-Level Technical Design

```text
AGENTS.md
  └─ repository supplement: source state, chezmoi, hosts, agents, secrets, verification
      └─ follows common rules from dot_agents/readonly_AGENTS.md

dot_agents/readonly_AGENTS.md (common instruction SSOT)
  ├─ dot_claude/readonly_CLAUDE.md.tmpl
  ├─ dot_codex/readonly_AGENTS.md.tmpl
  ├─ dot_config/opencode/readonly_AGENTS.md.tmpl
  └─ dot_pi/agent/private_readonly_AGENTS.md.tmpl
       └─ rendered shared content is identical; only target attributes/modes differ
```

The implementation is ordered shared core first, root supplement second, parity verification last. The root file must not duplicate the shared core merely to make the document longer; it must name the dependency and then concentrate on repository-specific decisions.

---

## Coverage Contract

The implementer must use the current files as the baseline and account for every section below. A section may be shortened, merged, or moved, but it may not disappear without its binding content appearing in a retained section or in the shared core.

| Current source area | Required compact destination | Preservation check |
|---|---|---|
| Root source-state, filename attributes, ignored source paths | `AGENTS.md` source/deployment section | chezmoi source-vs-`$HOME` boundary, attributes, non-dot metadata and source-only trees remain explicit |
| Script prefix policy, no teardown, numeric script tree | `AGENTS.md` apply lifecycle table | `run_onchange_` default, fingerprint rules, skip/retry trade-off, no-teardown alternatives, ordering and rename warning remain |
| Host facts, gate grammar, probe traps, shared partials | `AGENTS.md` facts/gates section | registry-only names, hook/template layers, fail-safe direction, render-time values, `!` YAML quoting, stat/include/glob traps, shared dispatcher and guard-call shape remain |
| System tree | `AGENTS.md` system configuration section | manifest gates/checks/removals, reload boundaries, network restart caution, data-not-script ownership remain |
| CLIProxyAPI | `AGENTS.md` infrastructure section | loopback-only, sterile source, injected Management secret, local panel, auth metadata validation, launcher allowlist, `-local-model`, readiness authority, rollback integrity, no agent route, unsupported writes remain |
| Dotagents, skills, compound-engineering, Claude plugins, Pi extension/settings/auth/MCP | `AGENTS.md` agent surfaces table plus focused bullets | each consumer, source data, target mode, OS/container gate, read-only/live-write boundary, plugin/skill install mechanism, OAuth and eager MCP behavior remain |
| Verification recipe and CI fallback | `AGENTS.md` verification section | stub `op`, empty config, throwaway destination, own `--source`, GitHub token handling, archive blind spot, rendered-script checks, CI artifact authority, no live deploy remain |
| Secrets | `AGENTS.md` secret handling section | 1Password references, age ciphertext, keyring-encrypted prompted values, fail-soft read vs get-or-create, no plaintext, `op whoami` caveat, GitLab PAT behavior remain |
| Single-source-of-truth bullets | `AGENTS.md` data ownership matrix | facts, packages, fonts, VSCodium, Solaar, Wi-Fi, KDE/GNOME, haptic, shared instructions, garden, and all agent data consumers remain locatable and current |
| Toolchain, OS parity, containers, repo delivery | `AGENTS.md` platform/delivery sections | mise vs externals, package hardening, Rust analyzer duplication, Python path, desktop/distro facts, fcitx/GDM/polkit/Studio/Plymouth rules, container allowlist, branch/commit/CI override remain |
| Shared routing, mirror, security, Git, layout, branch, commit, rebase, issue, CI, Figma, process, temp, Podman, browser, runtime, package, mise, glab rules | `dot_agents/readonly_AGENTS.md` | every current MUST/MUST NOT/SHOULD and safety exception remains in a compact section/table; root points here instead of copying generic prose |

The current concrete facts, paths, package names, environment variables, and commands are not to be generalized away when they are the only executable specification. They may be grouped into tables or referenced by their authoritative source file.

---

## Implementation Units

### U1. Compact and canonicalize the shared instruction core

- **Goal:** Reduce repetition in `dot_agents/readonly_AGENTS.md` while keeping it a complete, standalone common guardrail source for all four agent wrappers.
- **Requirements:** R1, R2, R3, R5, R6, R7; KTD1, KTD2, KTD3, KTD4, KTD6.
- **Dependencies:** none.
- **Files:**
  - `dot_agents/readonly_AGENTS.md` (modify).
  - `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, `dot_pi/agent/private_readonly_AGENTS.md.tmpl` (read-only verification; do not modify).
- **Approach:**
  - Keep the routing index and RFC-2119 convention at the top.
  - Preserve one compact section for each current common guardrail family. Combine adjacent short sections into tables where the command, prohibition, and exception can be read in one pass.
  - Keep the project layout rules that are easy to violate (garden/aoe ownership, bare vs non-bare shape, query arity, no worktree declarations, title/group identity) explicit; remove repeated examples only when the rule remains unambiguous.
  - Keep all branch safety checks, remote/pushed-branch conditions, default-branch exception, worktree-directory prohibition, and one-task/one-branch rule explicit.
  - Keep the CI terminal-state requirement and single native watch-call rule explicit; do not replace them with “follow CI policy.”
  - End with a concise statement that repository-level `AGENTS.md` may add or override this core and that the project file is the authority for repository-local rules.
- **Patterns to follow:** Existing RFC-2119 wording, the current shared section names, and the source-of-truth rule in root `AGENTS.md` that common instructions are edited only in `dot_agents/readonly_AGENTS.md`.
- **Test scenarios:**
  - **Common-rule inventory:** Each row in the shared half of the Coverage Contract has a surviving heading, table row, or explicit cross-reference; no generic prohibition becomes an unqualified suggestion.
  - **Guardrail edge cases:** The final text still distinguishes unpushed prefix-renames from branch creation/switching, shared-temp denial from per-user scratch, rootless Podman from Docker daemon assumptions, and `op` authentication failure from desktop-mediated `op read` success.
  - **Consumer safety:** All four existing wrapper files remain byte-for-byte unchanged and still contain exactly one `include` statement.
- **Verification:** Static review against the pre-edit file and the shared-rule inventory must show no lost exception, unsafe operation, or externalized rule without an accessible local reference.

### U2. Rewrite the root repository supplement around current contracts

- **Goal:** Make `AGENTS.md` materially shorter and more precise by removing duplicated generic rules and historical narrative while retaining all repository-specific execution contracts.
- **Requirements:** R1, R2, R4, R5, R6, R8, R9; KTD2, KTD3, KTD4, KTD5.
- **Dependencies:** U1.
- **Files:**
  - `AGENTS.md` (modify).
  - `CLAUDE.md` (read-only mirror verification; do not modify).
  - Referenced source files under `.chezmoidata/`, `.chezmoitemplates/`, `.chezmoiscripts/`, `.chezmoiexternals/`, `system/`, `dot_*`, `.ci/`, and `crates/` (read-only evidence only).
- **Approach:**
  - Start with a short “source state and common core” section: never edit `$HOME`, list the source filename attributes, identify `dot_agents/readonly_AGENTS.md` as the canonical common core, and state that this file supplies repository-specific rules and explicit overrides.
  - Replace long directory narratives with compact tables for script groups, partials, source-of-truth data, agent surfaces, platform gates, and verification. Retain each current path when it is needed to perform or verify an operation.
  - Rewrite facts/gates, system configuration, CLIProxyAPI, agent provisioning, Pi, secrets, and container sections in present tense. Keep safety-critical details (permissions, loopback scope, secret boundaries, fail-closed behavior, no-runtime-fetch claims, read-only/live-written distinctions, source-vs-runtime state, and retry/rollback semantics) as short normative bullets.
  - Consolidate repeated “this used to be…” explanations into one current contract or remove them when they do not prevent a future mistake. Do not remove the rationale for a fail-safe fact, stat-guarded include, no-teardown policy, encrypted garden, or isolated render because those rationales prevent unsafe execution.
  - Keep the exact verification recipe available through a concise reference to the existing recipe plus a checklist of what it proves; retain the archive’s target-vs-script blind spot and the CI-artifact fallback.
  - Preserve the root-specific commit/branch/delivery rules that supplement the shared core. Where wording duplicates the shared core, point to the shared section and state only the local override.
- **Patterns to follow:** The current “Single source of truth” section, `.chezmoidata` headers, `system/README.md`, `.ci/smoke-cli-proxy-api.sh`, and the four wrapper include templates. Prefer a present-tense contract table over a chronological explanation.
- **Test scenarios:**
  - **Repository-operability read-through:** A fresh agent can locate the source-state boundary, how to add facts/data/tools, how to avoid teardown and garden/worktree violations, how to handle secrets, and how to run isolated verification without consulting the removed prose.
  - **Safety edge cases:** The compact text still covers fail-safe false facts, no `FORCE_*` privilege leakage into system gates, no provider credentials in source/runtime/service definitions, owner/mode/hard-link validation for persistent auth, no plugin agent route through CLIProxyAPI, and no live deploy as verification.
  - **Current-source consistency:** Named consumers and paths in each retained table resolve to the current repository files; no historical deleted script or superseded mechanism remains presented as active behavior.
- **Verification:** Compare every root section to the Coverage Contract and the current source files. The final document must retain all current project-specific invariants while removing only duplicate, historical, or non-executable prose.

### U3. Prove source scope, render parity, and contract completeness

- **Goal:** Verify that the two rewritten sources are syntactically valid, materially smaller, internally consistent, and correctly propagated to every shared-instruction consumer.
- **Requirements:** R1, R2, R5, R6, R7, R8, R9; KTD6, KTD7.
- **Dependencies:** U1, U2.
- **Files:**
  - `AGENTS.md` and `dot_agents/readonly_AGENTS.md` (read-only validation after U1/U2).
  - The four wrapper templates listed in U1 (read-only validation).
  - `CLAUDE.md` (read-only mirror validation).
  - `.chezmoidata/`, `.chezmoitemplates/`, `.chezmoiscripts/`, `.chezmoiexternals/`, `.ci/`, and rendered archive inputs as required by the repository recipe (read-only validation).
- **Approach:**
  - Record baseline and final line/word/byte counts from `git show HEAD:<path>` and the working tree; report the reduction without setting a line count as a substitute for semantic review. The combined result must be materially smaller, with no invariant omitted to hit a number.
  - Run `git diff --check` and inspect the diff to confirm only the two requested source files changed. Confirm the root `CLAUDE.md` remains exactly `@AGENTS.md`.
  - Assert the shared source still has the complete common-rule inventory and the root source still has every row in the Coverage Contract. Use focused searches for load-bearing tokens (`MUST`, `MUST NOT`, `onepasswordRead`, `fact_gate`, `FORCE_`, `run_onchange_`, `archive --exclude`, `--source`, `OP_SERVICE_ACCOUNT_TOKEN`, `lifecycle`, `garden`, `aoe`, and `CLIProxyAPI`) as a review aid, not as the sole proof.
  - Use the AGENTS.md stub-`op` recipe with an empty config, `--source "$PWD"`, and a per-user throwaway destination to render each wrapper template. Assert all four outputs are byte-identical to each other and contain the rewritten shared text. Do not use a real `op`, live destination, or `chezmoi apply`.
  - If the full archive comparison is run, compare a baseline source tree and the branch using `--exclude=encrypted,externals,scripts`. Expect only the five generated instruction targets (`~/.agents/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, `~/.pi/agent/AGENTS.md`) to differ due to the shared-source rewrite; root `AGENTS.md` itself is ignored by the root `.chezmoiignore`. Any additional target diff is a regression to investigate.
  - Review the final files once in order, checking that cross-references resolve and that no compact table hides a condition, exception, or required command argument.
- **Patterns to follow:** The existing “Verify edits (don't eyeball raw `.tmpl`” section, stub-`op` recipe, archive target/script blind-spot warning, and root `CLAUDE.md` import convention.
- **Test scenarios:**
  - **Render happy path:** Each wrapper exits successfully under the isolated recipe and all four rendered contents match the shared source output.
  - **Scope failure path:** A diff or archive check that finds a changed wrapper, `CLAUDE.md`, generated non-instruction target, source data, script, or template fails the verification rather than being accepted as incidental.
  - **Syntax/content path:** `git diff --check` is clean; Markdown remains readable; all required contract markers and current source references are present; no unresolved old heading/reference introduced by restructuring remains.
- **Verification:** The implementation is complete only when the source diff is limited to the two requested files, the wrappers remain bare includes, the rendered shared output is identical across all four consumers, the root mirror is unchanged, and the inventory/read-through checks pass.

---

## Verification Contract

All commands run from the current worktree and use the repository's isolated render recipe. The implementer must not run a live deploy as a check.

1. **Scope and whitespace:** `git status --short`, `git diff --check`, and a path-limited diff show only `AGENTS.md` and `dot_agents/readonly_AGENTS.md` changed; no files are staged and `CLAUDE.md` remains the one-line `@AGENTS.md` import.
2. **Size evidence:** Compare `wc -l -w -c` for both baseline blobs (`git show HEAD:<path>`) and final files. Record the combined reduction and confirm it is material; do not trade away a required invariant solely to meet a numeric target.
3. **Shared inventory:** Read the final shared file against the shared rows of the Coverage Contract. Confirm every common guardrail family and every current exception remains explicit and normative.
4. **Root inventory:** Read the final root file against all repository rows of the Coverage Contract and current authoritative files. Confirm facts, gates, source-of-truth consumers, agent surfaces, secret boundaries, container fences, and verification obligations remain executable.
5. **Wrapper shape:** Confirm each of these is still a single include and unchanged in the diff: `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, and `dot_pi/agent/private_readonly_AGENTS.md.tmpl`.
6. **Isolated render:** With the stub `op`, empty config, `--source "$PWD"`, and throwaway destination from the root recipe, render all four wrappers. All exit successfully, and their outputs are byte-identical and contain the final shared instructions.
7. **Expected target graph:** If archive comparison is used, only the five generated instruction targets listed in U3 may change. A changed unrelated rendered target is a failure. The archive check must be supplemented by rendered-script checks when any script is touched; this task must touch none.
8. **Cross-reference and mirror:** Focused searches for removed headings/old section names, wrapper include paths, `@AGENTS.md`, and named verification/source-of-truth files find no broken or stale references. Root `CLAUDE.md` is exactly one import line.
9. **CI fallback:** If local `chezmoi` rendering is unavailable, do not claim it passed. Use the repository's `render-dotfiles.yml` rendered-files/rendered-internals artifacts and report the limitation; the documentation diff still requires the static inventory and scope checks.

No unit test file is added or updated: this is a pure instruction/documentation refactor, and the existing render and CI surfaces are the behavioral proof.

---

## Risks and Mitigations

- **Risk: a compact cross-reference is not available in a deployed context.** Mitigation: keep the repository-relative path and a one-sentence contract in the root file; do not replace executable content with “see elsewhere” unless the referenced source is part of this repository and is loaded by the same workflow.
- **Risk: security detail is lost during prose trimming.** Mitigation: treat secrets, age, auth metadata, CLIProxyAPI launcher/runtime, fact gates, container fences, and scratch/render isolation as protected sections; verify them against the Coverage Contract rather than line count.
- **Risk: root and shared rules drift after centralization.** Mitigation: explicitly label common-core ownership, retain only root overrides, and run a final contradiction sweep across both files.
- **Risk: generated target changes are broader than expected.** Mitigation: render all four wrappers and use the archive comparison only as an expected-five-target check; investigate any unrelated target diff.
- **Risk: upstream/dynamic content makes a full archive noisy.** Mitigation: exclude encrypted/externals/scripts exactly as the existing recipe requires, compare the same baseline and branch source, and rely on direct wrapper renders plus static checks for this documentation-only change.

---

## Definition of Done

- `AGENTS.md` and `dot_agents/readonly_AGENTS.md` are materially shorter and more precise than their baselines.
- Generic rules have one canonical owner in the shared source; the root file is a compact, operationally complete repository supplement.
- Every current binding rule, project invariant, safety guardrail, source-of-truth instruction, and verification obligation in the Coverage Contract is represented without a policy change.
- The four wrapper templates remain untouched one-line includes, and root `CLAUDE.md` remains `@AGENTS.md` only.
- Isolated rendering succeeds for all four wrappers with byte-identical shared output and no live `$HOME` or real 1Password access.
- The final source diff contains no file outside the two requested instruction sources and no staged files.
- Any residual ambiguity or discovered policy conflict is reported rather than silently resolved.

---

## Sources & Research

- `AGENTS.md` — current repository-specific instruction surface and its “Verify edits” recipe.
- `dot_agents/readonly_AGENTS.md` — current common instruction SSOT.
- `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, `dot_pi/agent/private_readonly_AGENTS.md.tmpl` — four one-line shared-source consumers.
- `CLAUDE.md` — root mirror convention (`@AGENTS.md`).
- `.chezmoiignore` — confirms root `AGENTS.md` is source metadata, not a deployed target.
- `.chezmoidata/`, `.chezmoitemplates/`, `.chezmoiscripts/`, `.chezmoiexternals/`, `system/`, `dot_*`, and `.ci/` — authoritative implementation surfaces named by the root instruction contract.
- No external research: the task is an in-repository documentation refactor with strong local patterns and no external product/API decision.
