---
title: A run_after Overlay of a chezmoi Archive-Owned File Makes the Next Apply Abort
date: 2026-09-17
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "a non-interactive chezmoi apply aborts with \"has changed since chezmoi last wrote it\" after a run_after script rewrote a file inside a localArchive external's extracted tree"
  - "the overlay script's own tests pass, because they install into a fixture archive and never run a chezmoi apply against a managed entry"
root_cause: design_limitation
resolution_type: config_change
severity: high
related_components:
  - tooling
tags:
  - chezmoi
  - localarchive
  - entrystate
  - overlay
  - run-after
  - compound-engineering
---

# A run_after Overlay of a chezmoi Archive-Owned File Makes the Next Apply Abort

## Problem

To run Compound Engineering's CLI elevation at `max` effort, a `run_after` script rewrote the plugin's `skills/ce-plan/scripts/elevation-dispatch.sh` and its `ce-brainstorm` twin inside the chezmoi-managed plugin archive. chezmoi still owned those paths, so the next non-interactive `chezmoi apply` would abort on drift.

## Symptoms

- chezmoi records the archive's digest as the entry's last-written state. After the overlay, the target matches neither that state nor the source, and a non-interactive apply stops with "has changed since chezmoi last wrote it". The code review's correctness reviewer found this. The validator confirmed it from `chezmoi state dump` entry state on chezmoi v2.72.1. A live apply was not run.
- `.ci/test-compound-engineering-overlays.sh` stayed green. It installs into a fixture archive and never runs `chezmoi apply` against a managed entry, so it cannot see apply-to-apply drift.

## What Didn't Work

- **A whole-file overlay of the archive-owned file.** The path stays inside the external's tracked tree, so every later apply sees drift.
- **A digest-guarded replacement** (replace only while the file still matches the recorded upstream digest). This limits when the write happens, but chezmoi still owns the path, so the drift remains. This was the first shipped version on this branch.
- **An in-place line edit.** Same ownership problem, and it would duplicate the installer's existing whole-file copy path.

## Solution

Take the paths out of chezmoi's ownership, then let the overlay script own them.

1. Add both adapter paths to the `exclude` list of both localArchive authorities (`home/.chezmoidata/agents.yaml:219-224` for `compound-engineering-plugin`, `:239-245` for `compound-engineering-omp`), next to the existing `*/skills/ce-sweep/references/interview.md` entry (and the later `gitlab-issues.md` entry), which use the same mechanism.
2. In `home/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl`, install the overlays via a patch-based architecture:
   - Upstream pre-images and post-images (sha256 and mode) are recorded in `base.json` (`home/dot_local/share/compound-engineering-overlays/base.json`), and individual customizations are maintained as patches (`home/dot_local/share/compound-engineering-overlays/patches/`).
   - An include-only archive external extracts unmodified upstream files to `~/.local/share/compound-engineering-pristine/<segment>/`.
   - The script applies patches in a private scratch git repository, verifying post-image digests before installing them into both target directories (`compound-engineering` and `compound-engineering-omp`).
   - A version mismatch, digest mismatch, or patch failure causes all paths to gracefully degrade together by restoring pristine upstream files.
3. Release lock gating via `.ci/ce-overlay-lock-hold.sh` and `.ci/check-ce-overlay-patches.sh` validates candidate Compound Engineering releases against the overlay patches during the hourly refresh, holding back the version bump and preserving the committed pin if patches do not cleanly apply. Comprehensive verification is maintained in `.ci/test-compound-engineering-overlays.sh`.

The initial fix landed on branch `feature/fable-max-effort-drop-flash-lite` for issue #535, followed by the patch-based overlay refactor in `docs/plans/2026-09-18-2330-refactor-ce-overlays-validated-patches-plan.md`.

## Why This Works

chezmoi's drift check compares every tracked entry with its last-written state, whoever changed it and however carefully. A guard on the write cannot remove that conflict; only removing the path from the tracked set can. `exclude` does that, so chezmoi has nothing to compare. The version and digest guards then solve the remaining, ordinary problem: never overwrite upstream content the fork was not built from.

## Prevention

- Before a `run_after` or `run_onchange` script writes under the `externalPath` of an archive or localArchive external, exclude that exact path from the external. `home/.chezmoiexternals/dev-tools.toml` records the same hazard for the Flutter SDK, which is why Flutter is not an archive external at all.
- Pin a whole-file fork of a third-party file to both its upstream version and digest, and degrade (warn, leave unchanged) on any mismatch instead of aborting or installing.
- When an unattended process can bump the upstream pin, add a CI check that fails on the bump until the fork is refreshed.
- Keep apply-time installers bash 3.2 and macOS safe: macOS has no `sha256sum` (fall back to `shasum -a 256`) and bash 3.2 has no `declare -A`. A missing tool must skip with a warning, never abort under `set -euo pipefail` (`home/.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl`).

## Related

- `docs/solutions/integration-issues/chezmoi-worktree-root-etc-file-deployment.md` — another case where chezmoi's state model does not fit an outside writer.
- `docs/solutions/integration-issues/chezmoi-template-required-field-guard-accepts-null.md` — a chezmoi guard that its own fixtures could not exercise.
