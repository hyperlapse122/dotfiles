---
title: "fix: exclude interview overlay in compound-engineering external"
date: 2026-08-23
type: fix
topic: exclude-compound-engineering-interview-overlay
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Fix: Exclude Interview Overlay in compound-engineering External

## Goal Capsule

- **Objective:** Prevent chezmoi from prompting or warning about modified files (`.local/share/compound-engineering/v3.23.1/skills/ce-sweep/references/interview.md has changed since chezmoi last wrote it?`) during `chezmoi apply` or `chezmoi update`.
- **Product authority:** `.chezmoidata/agents.yaml` declares archive externals and their exclusions for `localArchive` marketplaces.
- **Open blockers:** None.

## Problem Frame

When applying or updating dotfiles via `chezmoi update` or `chezmoi apply`, chezmoi detects that `.local/share/compound-engineering/v3.23.1/skills/ce-sweep/references/interview.md` has changed since chezmoi last wrote it and prompts the user for overwrite confirmation.

### Root Cause
1. `.chezmoiexternals/ai-agents.toml` defines `.local/share/compound-engineering/v3.23.1` as an external archive from GitHub (`EveryInc/compound-engineering-plugin`).
2. During archive extraction, chezmoi writes the upstream version of `skills/ce-sweep/references/interview.md` and records its checksum in chezmoi's entry state.
3. Later in the apply sequence, `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl` copies the local overlay `~/.local/share/compound-engineering-overlays/skills/ce-sweep/references/interview.md` over the extracted file.
4. Because the local overlay differs from the upstream archive file, chezmoi's drift detection flags the file on subsequent applies and prompts for interactive overwrite.
5. This matches the exact failure mode previously fixed for `plugin.json` in commit `ecb7da6`.

## Requirements

- R1. Add `"*/skills/ce-sweep/references/interview.md"` to the `exclude` list for `compound-engineering-plugin` in `.chezmoidata/agents.yaml`.
- R2. Ensure `.chezmoiexternals/ai-agents.toml` continues rendering `exclude = {{ toJson $authority.exclude }}` for `localArchive` marketplaces so chezmoi skips extracting upstream `interview.md`.
- R3. Update `.ci/test-compound-engineering-overlays.sh` to assert both `"*/plugin.json"` and `"*/skills/ce-sweep/references/interview.md"` in the rendered exclude list.
- R4. Verify all tests pass and `chezmoi execute-template` renders the expected exclusion without syntax or rendering errors.

## Success Criteria

- `.ci/test-compound-engineering-overlays.sh` passes completely.
- `chezmoi execute-template < .chezmoiexternals/ai-agents.toml` renders `exclude = ["*/plugin.json","*/skills/ce-sweep/references/interview.md"]` for the compound-engineering block.
- Subsequent `chezmoi apply` / `chezmoi update` runs do not prompt about `interview.md`.

## Implementation Steps

1. **U1: Update `.chezmoidata/agents.yaml`**
   - Add `"*/skills/ce-sweep/references/interview.md"` under `agents.marketplaces.compound-engineering-plugin.exclude`.
2. **U2: Update `.ci/test-compound-engineering-overlays.sh`**
   - Update comment on line 15 to reference both `plugin.json` and `interview.md`.
   - Update assertion on line 196 to verify `exclude = ["*/plugin.json","*/skills/ce-sweep/references/interview.md"]`.
3. **U3: Run verification tests**
   - Run `.ci/test-compound-engineering-overlays.sh "$PWD"`.
   - Run `chezmoi execute-template < .chezmoiexternals/ai-agents.toml`.
