# Residual Review Findings — ethiopians

Source run: LFG pipeline for issue #100 (static release-artifact lock), branch `ethiopians`, head at review time `c2a8d75909466638d87e5f1d1eb5cc4313e29b23`.

Review artifact: `/tmp/compound-engineering-1000/ce-code-review/20260727-192146-95726e9d/review.json` (run id `20260727-192146-95726e9d`).

Findings #3, #4, #8, #9 were eligible for handoff (confidence 75, single-persona) but not eligible for the in-pipeline apply step (which requires confidence 100 or cross-persona agreement). They are deferred to the tracker below.

## Residual Review Findings

- **P1** `packages/release-lock/src/cli.ts:58` — cli.ts dispatch, failure carry-forward, and lock emission shape untested → https://github.com/hyperlapse122/dotfiles/issues/103
- **P1** `packages/release-lock/src/registry.ts:172` — Registry asset selectors (URL byte-parity core) have no committed test → https://github.com/hyperlapse122/dotfiles/issues/104
- **P2** `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md:359` — Plan's R12/DoD4/U5 promise checksum verification for all tools, but the code keeps verification at the pre-existing set → https://github.com/hyperlapse122/dotfiles/issues/105
- **P2** `packages/release-lock/src/cli.ts:13` — Refresh carry-forward (R11) is procedural, not structural: partial refresh blanks lock entries and breaks every host render → https://github.com/hyperlapse122/dotfiles/issues/106

Also noted (report-only, not deferred): finding #11 — `dot_pi` pi-extensions reads `.releases.tools` directly instead of `release-lock-ref.tmpl` (P3 advisory, owner human); finding #7 was dropped by the validator as resting on stale pre-diff plan text.
