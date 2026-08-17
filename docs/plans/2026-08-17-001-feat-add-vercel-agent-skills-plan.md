---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "feat: add vercel-labs agent skills to agents configuration"
date: 2026-08-17
type: feat
depth: lightweight
---

# feat: Add vercel-labs agent skills to agents configuration

## Goal Capsule

- **Objective:** Add five skills from `vercel-labs/agent-skills` (`composition-patterns`, `react-best-practices`, `react-view-transitions`, `web-design-guidelines`, `writing-guidelines`) to `.chezmoidata/agents.yaml`, register them in `packages/release-lock`, and update the lockfile `.chezmoidata/releases.json`.
- **Authority:** The user request specifies the five skill URLs from `https://github.com/vercel-labs/agent-skills`. Repository rules in `AGENTS.md` mandate data-driven external skills via `.chezmoidata/agents.yaml` and static release resolution via `packages/release-lock` and `.chezmoidata/releases.json`.
- **Execution profile:** Declarative chezmoi data additions, release-lock tool registration, lockfile generation, and template render verification.
- **Stop conditions:** Stop if `vercel-labs/agent-skills` cannot be resolved via `gitRef`, if `.chezmoiexternals/ai-agents.toml` fails to render the archive definitions, or if release-lock test assertions fail.
- **Tail ownership:** The caller owns commit, push, pull request, and CI handling after implementation and review.

## Product Contract

### Summary

Manage five additional external AI agent skills from `vercel-labs/agent-skills` in the chezmoi source state: `composition-patterns`, `react-best-practices`, `react-view-transitions`, `web-design-guidelines`, and `writing-guidelines`.

### Problem Frame

The repository manages external agent skills under `~/.agents/skills/<name>`. Currently, skills like `agent-browser`, `improve`, `i-have-adhd`, `glab`, and `glab-stack` are declared in `.chezmoidata/agents.yaml` under `agents.skills.external`. The user requested adding five skills from `vercel-labs/agent-skills`. Because this repository strictly enforces zero-network-IO template rendering via `.chezmoidata/releases.json`, adding external skills requires declaring them in `agents.skills.external`, registering their `gitRef` source in `packages/release-lock/src/registry.ts`, and updating the locked commit sha in `.chezmoidata/releases.json`.

### Requirements

- R1. Add `composition-patterns`, `react-best-practices`, `react-view-transitions`, `web-design-guidelines`, and `writing-guidelines` to `.chezmoidata/agents.yaml` under `agents.skills.external` with `source: vercel-labs/agent-skills` and `ref: main`.
- R2. Register all five skills in `packages/release-lock/src/registry.ts` with `kind: "gitRef"`, `source: "vercel-labs/agent-skills"`, and `ref: "refs/heads/main"`.
- R3. Update `.chezmoidata/releases.json` with the locked git commit sha for all five skills using the release-lock tooling.
- R4. Verify that `.chezmoiexternals/ai-agents.toml` renders valid archive externals for all five skills targeting `.agents/skills/<name>` with `stripComponents = 3` and `include = ["*/skills/<name>/**"]`.
- R5. Ensure all `packages/` tests and TypeScript checks pass.

### Scope Boundaries

**In scope:**
- `.chezmoidata/agents.yaml`
- `packages/release-lock/src/registry.ts`
- `.chezmoidata/releases.json`
- Render verification of `.chezmoiexternals/ai-agents.toml`
- Package test execution

**Out of scope:**
- Modifying deployed files in `$HOME`
- Changing skill extraction logic or template structure
- Modifying other externals or agent configurations

### Dependencies

- `.chezmoiexternals/ai-agents.toml` renders `.agents/skills/<name>` archive blocks.
- `packages/release-lock` resolves `gitRef` sources to commit shas.
- `.chezmoitemplates/release-lock-ref.tmpl` reads versions from `.chezmoidata/releases.json`.

## Planning Contract

### Key Technical Decisions

- KTD1. **Use `gitRef` with `refs/heads/main`.** `vercel-labs/agent-skills` has no release tags, only branch heads. Following the pattern of `improve` (`shadcn/improve`) and `i-have-adhd` (`ayghri/i-have-adhd`), we register each skill as `kind: "gitRef"` tracking `refs/heads/main` and declare `ref: main` in `agents.yaml`.
- KTD2. **Separate tool entries per skill.** Even though the five skills share one GitHub repository (`vercel-labs/agent-skills`), `.chezmoiexternals/ai-agents.toml` resolves `release-lock-ref.tmpl` keyed on `.name` (`dict "tool" .name`). Therefore, each skill must be registered as a distinct tool key in `REGISTRY` and `.chezmoidata/releases.json`.
- KTD3. **Automated lockfile update via `packages/release-lock`.** Use `cli.ts` from `packages/release-lock` to resolve and merge the new tools into `.chezmoidata/releases.json` rather than hand-crafting JSON.

### Sequencing

1. Register the 5 tools in `packages/release-lock/src/registry.ts`.
2. Run `packages/release-lock` CLI to resolve and write `.chezmoidata/releases.json`.
3. Add the 5 skills to `agents.skills.external` in `.chezmoidata/agents.yaml`.
4. Render `.chezmoiexternals/ai-agents.toml` and verify the generated archive blocks.
5. Run workspace tests and typechecks across `packages/`.

## Implementation Units

### U1. Register tools and update releases.json

- **Goal:** Register the 5 `vercel-labs/agent-skills` tools in `packages/release-lock/src/registry.ts` and generate lock entries in `.chezmoidata/releases.json`.
- **Requirements:** R2, R3, R5; KTD1, KTD2, KTD3.
- **Files:** `packages/release-lock/src/registry.ts`, `.chezmoidata/releases.json`.
- **Approach:** Add the five `gitRef` definitions to `REGISTRY` in `registry.ts`. Run `release-lock` CLI to fetch and record the commit SHA into `.chezmoidata/releases.json`. Run unit tests in `packages/release-lock`.

### U2. Declare skills in agents.yaml and verify externals rendering

- **Goal:** Declare the 5 skills in `.chezmoidata/agents.yaml` and verify rendering of `.chezmoiexternals/ai-agents.toml`.
- **Requirements:** R1, R4.
- **Files:** `.chezmoidata/agents.yaml`.
- **Approach:** Add `composition-patterns`, `react-best-practices`, `react-view-transitions`, `web-design-guidelines`, and `writing-guidelines` under `agents.skills.external`. Execute chezmoi template render against `.chezmoiexternals/ai-agents.toml` and confirm the generated TOML sections.

## Verification Contract

| Check | Scope | Pass signal |
| --- | --- | --- |
| Release lock registry tests | `packages/release-lock` | `vp run -r test` in `packages/` passes all tests. |
| Typecheck & format | `packages/` | `vp run -r typecheck && vp check` passes. |
| Template render | `.chezmoiexternals/ai-agents.toml` | `chezmoi execute-template < .chezmoiexternals/ai-agents.toml` produces valid TOML with archive entries for all 5 skills and resolved commit SHAs. |
| Repository diff | Repository | `git diff --check` passes with no whitespace errors. |

## Definition of Done

- All 5 skills are declared in `.chezmoidata/agents.yaml`.
- All 5 skills are registered in `packages/release-lock/src/registry.ts` and locked in `.chezmoidata/releases.json`.
- `.chezmoiexternals/ai-agents.toml` renders properly without errors.
- Package tests, typechecking, and code quality checks pass.
