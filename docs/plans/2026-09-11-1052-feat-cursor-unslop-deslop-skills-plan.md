---
title: Cursor unslop and deslop Agent Skills - Plan
type: feat
date: 2026-09-11
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Cursor unslop and deslop Agent Skills - Plan

## Goal Capsule

- **Objective:** The `unslop` and `deslop` skills are installed and available to every agent harness on a managed host, pinned and updated by the same declarative mechanism as every other managed skill. Available means present in the harness's skill set; `unslop` ships `disable-model-invocation: true`, so under Claude Code it is user-invocable only (see Assumptions).
- **Means:** Declare both skills in `.chezmoidata/agents.yaml` and give each one a `gitRef` release-lock key, because `cursor/plugins` publishes no releases or tags (KTD1, KTD2).
- **Authority:** This plan for scope and sequencing; `.chezmoiexternals/ai-agents.toml` for the external contract each entry must satisfy; the repository `AGENTS.md` for delivery rules.
- **Execution profile:** Declarative data and one TypeScript registry edit. No runtime code paths change.
- **Stop conditions:** Stop and report if the render of `.chezmoiexternals/ai-agents.toml` fails, if upstream moves or removes either skill subtree, or if the orca audit lists a `stablyai/orca` skill absent from `.chezmoidata/agents.yaml` — do not add it under this plan.
- **Tail ownership:** LFG owns commit, push, PR, and CI watch.

---

## Product Contract

### Summary

Add two Cursor-published agent skills — `unslop` (`pstack/skills/unslop`) and `deslop` (`cursor-team-kit/skills/deslop`) — to the managed skill set in `.chezmoidata/agents.yaml`. Both live in the `cursor/plugins` monorepo, which has no releases and no tags, so each needs a branch-pinned `gitRef` entry in the release-lock registry and a resolved commit sha in the committed lock. The requested audit of `stablyai/orca` skills found no gap: all eight upstream skills are already declared, so that part of the request needs no change.

### Problem Frame

The user wants two Cursor writing- and code-cleanup skills available to their agents. Managed skills are not installed ad hoc; `.chezmoiexternals/ai-agents.toml` ranges over `agents.skills.external` and emits one chezmoi external per entry, and every entry's ref is read from `.chezmoidata/releases.json` and fails closed when the key is missing. A skill added to the YAML list alone therefore breaks `chezmoi apply` on every host instead of installing anything. The same request asked whether any `stablyai/orca` skill is missing from the managed set, because that list grew by hand.

### Requirements

**New skill declarations**

- R1. `.chezmoidata/agents.yaml` declares `unslop` with `source: cursor/plugins` and `skillPath: pstack/skills/unslop`.
- R2. `.chezmoidata/agents.yaml` declares `deslop` with `source: cursor/plugins` and `skillPath: cursor-team-kit/skills/deslop`.
- R3. Both entries carry `ref: main`, because `cursor/plugins` publishes neither releases nor tags, and the no-`ref` branch of `.chezmoiexternals/ai-agents.toml` expects a release tag.

**Pinning**

- R4. `packages/release-lock/src/registry.ts` holds one `gitRef` spec per new skill, keyed on the skill name, with `source: "cursor/plugins"` and `ref: "refs/heads/main"`.
- R5. `.chezmoidata/releases.json` holds a resolved 40-hex commit sha for each new key, in the same `{kind, source, version}` shape as the existing `gitRef` entries.

**Orca coverage**

- R6. The `stablyai/orca` skill set in `.chezmoidata/agents.yaml` is verified complete against upstream and left unchanged when no skill is missing.

### Key Decisions

- **Pin `cursor/plugins` to its `main` branch head rather than a release.** Governs R3, R4. The repository has zero releases and zero tags, so no other ref exists.
- **Treat the orca audit as a verification, not a change.** Governs R6. All eight upstream skills are already declared, so declaring anything further would invent scope.

### Scope Boundaries

- In scope: the two new skill declarations, their registry specs, and their lock entries.
- Out of scope: adding any other `cursor/plugins` skill. The repository ships 47 skills under `pstack/skills` and 18 under `cursor-team-kit/skills`; the user named two.
- Out of scope: changing how `agents.skills.external` is rendered, ordered, or validated.
- Out of scope: a new CI gate asserting that every `agents.skills.external` name has a registry key. The render already fails closed, and adding a gate exceeds the request.

### Sources

- `.chezmoiexternals/ai-agents.toml` — the `range .agents.skills.external` block: the `versionSource`/`ref`/no-key ref rule, the `skillPath` cleanliness check, `stripComponents = 1 + len(segments)`, and `include = ["*/<skillPath>/**"]`.
- `packages/release-lock/src/registry.ts:331-365` — the existing `gitRef` block, with `improve` as the closest precedent.
- `packages/release-lock/src/git-ref.ts` — `gitRef` resolves `git ls-remote <source> <ref>` to a 40-hex sha and records it as `version`.
- `packages/release-lock/src/lock.ts:15` — the lock's `tools` map is serialized in `localeCompare` order.
- `.github/workflows/refresh-release-lock.yml` — the resolver runs only on schedule and dispatch against the default branch, so a pull request must carry its own new lock entries.
- Upstream listing at `cursor/plugins@main`: `pstack/skills/unslop/` and `cursor-team-kit/skills/deslop/` each contain exactly one file, `SKILL.md`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Declare both skills with `ref: main`.** `.chezmoiexternals/ai-agents.toml` picks the ref by key shape: `versionSource` uses the shared glab tag, a `ref` key resolves that branch head through the release lock, and no key at all expects a release tag. `cursor/plugins` has no releases, so `ref: main` is the only branch that produces a resolvable ref. Instantiates the `main`-pinning Key Decision; governs R3.

  **Trust boundary, accepted.** `cursor/plugins@main` is an unreviewed upstream. An agent skill is instruction text a harness follows, and the hourly `refresh-release-lock.yml` re-resolves both branch-head pins with no human in the loop, so any commit to that branch reaches every managed host on the next apply without review. This is the same posture the five branch-pinned `vercel-labs/agent-skills` entries and `shadcn/improve` already carry; it is recorded here rather than changed, because gating `gitRef` pin advances behind a reviewed pull request is a change to the refresh mechanism and outside this plan's scope.
- KTD2. **Add one `gitRef` registry spec per skill, not one per repository.** `.chezmoiexternals/ai-agents.toml` looks the lock up by *skill name*, so two skills from one repository need two keys — the same shape the five `vercel-labs/agent-skills` skills and the eight `stablyai/orca` skills already use. Governs R4.
- KTD3. **Write the resolved shas into `.chezmoidata/releases.json` in this change.** The refresh workflow runs on a schedule against the default branch only, and the render reads the lock fail-closed. Without the lock entries, `chezmoi apply` dies on the merge commit and stays dead until the next hourly refresh. Governs R5.
- KTD4. **Keep the archive external form, unchanged.** Each skill subtree is a single `SKILL.md`, so the gitlab single-file branch would also work — but that branch is reachable only via `host: gitlab`, and a subtree that later gains a `references/` directory is served correctly by the archive form and silently truncated by the single-file form.

### Implementation constraints

- `stripComponents` is computed as `1 + len(splitList "/" skillPath)`. Both new `skillPath` values have three segments, so both render `stripComponents = 4`, dropping `plugins-<sha>/<skillPath>/` and leaving `SKILL.md` at the target root. No manual arithmetic is needed; the template computes it.
- `skillPath` must be a clean relative path — no leading, trailing, or doubled separator, and no `.`/`..` segment — or the render fails by design.
- `versionSource` and `ref` are mutually exclusive; neither new entry may carry `versionSource`.
- The lock's `tools` map is sorted by `localeCompare`. Insert `deslop` between `computer-use` and `docker-credential-helpers`, and `unslop` between `teamviewer` and `uv`, so the next resolver run produces no reordering diff.
- Per the repository's comment discipline, add a comment only where it records a non-obvious constraint. The "no releases, hence `ref: main`" fact qualifies; a comment restating the source URL does not.

### Assumptions

- The commit sha `f5bdd6826fd0a0d9cbc4347134c3a74a200b9d9d` is `cursor/plugins@main` as of this plan. Re-resolve it at implementation time with `git ls-remote https://github.com/cursor/plugins.git refs/heads/main`; the hourly refresh will advance it after merge either way.
- `unslop`'s `SKILL.md` frontmatter carries `disable-model-invocation: true`. The key passes through installation harmlessly: the omp frontmatter-rejection problem recorded in `.chezmoidata/agents.yaml` applies to agent-plugin *packages*, not to individual external skills, and no gate in this repository inspects external skill frontmatter. It is not harmless to invocability. Under Claude Code the key withholds the skill from model selection and leaves it user-invocable as `/unslop`; a harness that does not recognize the key may still select it autonomously, and upstream's own description says "Must always apply". The plan ships the key verbatim as upstream wrote it; normalizing it is a separate policy call.

### Sequencing

U1 and U2 pin the skills; U3 declares them. U3 cannot render until U1 and U2 land, so keep the order. Verification runs once, after U3.

---

## Implementation Units

### U1. Register both skills as `gitRef` tools

- **Goal:** The release-lock resolver knows how to resolve `unslop` and `deslop`.
- **Requirements:** R4.
- **Files:** `packages/release-lock/src/registry.ts`
- **Approach:** Add two entries to the `gitRef` block (currently `packages/release-lock/src/registry.ts:329-365`), following the `improve` entry's shape: `{ kind: "gitRef", source: "cursor/plugins", ref: "refs/heads/main" }` under the keys `unslop` and `deslop`. Carry one short comment, above the pair, recording that `cursor/plugins` publishes no releases or tags — the same fact the `improve` comment records for its own source. Do not add a per-entry comment repeating it.
- **Test scenarios:** None — this is a declarative registry addition with no logic. `Test expectation: none -- pure data registration, covered by the resolver run below.` Note what the other gates do *not* cover: typecheck proves only that the object satisfies `ToolSpec`, and no render or lock gate ever reads `registry.ts` — `release-lock-ref.tmpl` is the lock's sole consumer. A mistyped key, source, or ref is a plain string that passes both. Running the resolver is the only check that reads the registry.
- **Verification:** `bun run --cwd packages typecheck` and `bun run --cwd packages check` both pass. Then run `bun run packages/release-lock/src/cli.ts --stdout` and confirm it resolves `unslop` and `deslop` to the same shas U2 records; discard the output rather than writing it, so the lock stays as U2 wrote it.

### U2. Record the resolved commit shas in the lock

- **Goal:** `.chezmoidata/releases.json` carries a resolvable version for both new keys, so the render does not fail closed on the merge commit.
- **Requirements:** R5.
- **Files:** `.chezmoidata/releases.json`
- **Approach:** Resolve the sha with `git ls-remote https://github.com/cursor/plugins.git refs/heads/main`. Insert two `releases.tools` entries in `localeCompare` position — `deslop` after `computer-use`, `unslop` after `teamviewer` — each `{"kind": "gitRef", "source": "cursor/plugins", "version": "<sha>"}`, matching the existing `improve` entry exactly. Both entries carry the same sha, because both skills come from the same branch head.
- **Test scenarios:** None — generated-shape data mirroring the resolver's own output. `Test expectation: none -- lock data, covered by the assertion below and the render check.`
- **Verification:** Assert the two entries directly, because `.ci/check-release-lock-digests.sh` walks only `.artifacts` and a `gitRef` entry has none, so it proves nothing about these two beyond the lock being valid JSON:

  ```bash
  jq -e '[.releases.tools.unslop, .releases.tools.deslop]
         | all(.kind == "gitRef" and .source == "cursor/plugins"
               and (.version | test("^[0-9a-f]{40}$")))' .chezmoidata/releases.json
  ```

  Then `jq -r '.releases.tools | keys_unsorted' .chezmoidata/releases.json` shows both new keys in sorted position, and `.ci/check-release-lock-digests.sh` still passes for the rest of the lock.

### U3. Declare both skills in the managed external list

- **Goal:** `.chezmoiexternals/ai-agents.toml` emits an archive external for each new skill, landing it at `~/.agents/skills/<name>/`.
- **Requirements:** R1, R2, R3.
- **Files:** `.chezmoidata/agents.yaml`
- **Approach:** Append two entries at the end of `agents.skills.external`, after `glab-stack`, so they sit beside the other `skillPath`-bearing entries:

  ```yaml
  - name: unslop
    source: cursor/plugins
    ref: main
    skillPath: pstack/skills/unslop
  - name: deslop
    source: cursor/plugins
    ref: main
    skillPath: cursor-team-kit/skills/deslop
  ```

  Add one comment above the pair recording the non-obvious constraint: `cursor/plugins` is a monorepo with no releases or tags, so each skill needs both a `skillPath` and a branch `ref`. Do not restate what the field names already say.
- **Test scenarios:**
  - Rendering `.chezmoiexternals/ai-agents.toml` emits a `[".agents/skills/unslop"]` stanza with `type = "archive"`, `exact = true`, `stripComponents = 4`, `include = ["*/pstack/skills/unslop/**"]`, and a URL of the form `https://github.com/cursor/plugins/archive/<40-hex sha>.tar.gz`.
  - The same render emits `[".agents/skills/deslop"]` with `stripComponents = 4` and `include = ["*/cursor-team-kit/skills/deslop/**"]`.
  - The render emits no `versionSource` failure and no `skillPath must be a clean relative path` failure.
  - Removing either lock entry makes the render fail loudly rather than emitting an unpinned URL — confirms the fail-closed path KTD3 depends on.
- **Verification:** `chezmoi execute-template --source "$PWD" < .chezmoiexternals/ai-agents.toml` renders both stanzas as described. Run it from the worktree holding the change. `--init` suppresses `.chezmoidata`, so the render aborts at the `claude` stanza before reaching the skills range; without `--source "$PWD"` chezmoi uses the configured `sourceDir`, which is the primary checkout, so the gate greens without ever reading these entries. `.ci/check-external-checksum-coverage.sh` renders the same file the same way.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Types and lint | `bun run --cwd packages typecheck` and `bun run --cwd packages check` | U1's registry entries satisfy `ToolSpec` and the formatting CI's `ts-workspace` job enforces. |
| Registry resolves | `bun run packages/release-lock/src/cli.ts --stdout` | U1's keys resolve upstream to the shas U2 records — the only gate that reads `registry.ts`. |
| Lock entries | The `jq -e` assertion in U2 | U2's two entries carry `kind: gitRef`, the right source, and a 40-hex version. |
| Lock shape | `.ci/check-release-lock-digests.sh` | The lock's artifact-bearing entries stay intact. It asserts nothing about `unslop` and `deslop`, which have no `artifacts` key. |
| Lock gate self-test | `.ci/test-release-lock-digest-gate.sh` | The gate itself still behaves. |
| Render | `chezmoi execute-template --source "$PWD" < .chezmoiexternals/ai-agents.toml`, run from this worktree | U3's entries render both externals with the expected `stripComponents` and `include`. |
| Orca audit | `gh api repos/stablyai/orca/contents/skills --jq '.[].name'` compared against the `source: stablyai/orca` entries in `.chezmoidata/agents.yaml` | R6 — no orca skill is missing. |

CI additionally runs the full `.ci` suite and the `render-dotfiles` workflow on the pull request; both must be green.

---

## Definition of Done

**Global**

- R1 through R6 are satisfied.
- Every gate in the Verification Contract passes locally, and CI is green on the pull request.
- No exploratory or dead-end edit remains in the diff.
- The orca audit result is stated in the pull request body, so a reader learns that part of the request needed no change.

**Per unit**

- U1: `unslop` and `deslop` appear in the `gitRef` block of `packages/release-lock/src/registry.ts` with `source: "cursor/plugins"` and `ref: "refs/heads/main"`; typecheck and `check` pass; the resolver run resolves both keys to the shas U2 records.
- U2: both keys exist in `.chezmoidata/releases.json` with a 40-hex `version`, in `localeCompare` position; the `jq -e` assertion passes.
- U3: both entries exist in `agents.skills.external`; the render emits both archive stanzas with `stripComponents = 4` and the correct `include` glob.
