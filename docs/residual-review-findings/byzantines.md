# Residual Review Findings — byzantines

Source run: LFG feedback-sweep pipeline, branch `byzantines`, reviewed head `bf8998b77961d12dbefe6a625c13879ee6acf5ce`. Review-fix commit: `56f9e2c`.

Review artifact: `/tmp/compound-engineering-1000/ce-code-review/20260814-095554-f0122136/review.json` (run id `20260814-095554-f0122136`).

Eight actionable downstream-resolver findings were not eligible for the in-pipeline apply step because they required a design decision or had confidence 75 without cross-persona agreement. Tracker defer filed all eight as GitHub Issues. No filing failures or no-sink findings occurred.

## Residual Review Findings

- **P1** `.ci/test-capability-cache.sh:689` — Darwin capability test blesses unavailable tokens for active consumers → https://github.com/hyperlapse122/dotfiles/issues/220
- **P1** `.chezmoiscripts/30-linux/run_onchange_after_setup-podman-cluster.sh.tmpl:128` — Podman retry declaration uses wrong lifecycle and probe → https://github.com/hyperlapse122/dotfiles/issues/221
- **P1** `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-touchpad.sh.tmpl:68` — KWin-unreachable blocking skip names a probe that cannot track KWin → https://github.com/hyperlapse122/dotfiles/issues/222
- **P1** `.ci/test-merge-commit-only-gates.sh:324` — Merge gate never asserts which REST field the resolver reads → https://github.com/hyperlapse122/dotfiles/issues/223
- **P2** `.chezmoiscripts/50-linux-gnome/run_onchange_after_config-gnome-fonts.sh.tmpl:41` — GNOME font guidance still promises manual force → https://github.com/hyperlapse122/dotfiles/issues/224
- **P2** `.ci/check-skip-declarations.sh:339` — Skip guard cannot see a one-line case-arm exit, so it passes undeclared → https://github.com/hyperlapse122/dotfiles/issues/225
- **P2** `.install-prerequisites.sh:470` — Capability snapshot can hang on user-manager D-Bus probe → https://github.com/hyperlapse122/dotfiles/issues/226
- **P2** `dot_local/bin/executable_git-prune-local-branches:223` — Branch pruner can hang on remote auth or network failure → https://github.com/hyperlapse122/dotfiles/issues/227

The review also reported manual design findings #2 and #3 (the size and hand-maintenance shape of the CI checker and matrix). They remain report-only in the review artifact and were not routed as downstream-resolver residuals.
