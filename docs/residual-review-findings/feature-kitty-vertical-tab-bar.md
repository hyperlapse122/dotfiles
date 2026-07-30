# Residual Review Findings — feature/kitty-vertical-tab-bar

Source run: LFG pipeline for the kitty vertical tab bar migration, branch `feature/kitty-vertical-tab-bar`, plan `docs/plans/2026-07-30-001-feat-kitty-vertical-tab-bar-plan.md`.

Review: one independent reviewer pass against the plan and the working-tree diff. Two findings, both handled in-pipeline; one leaves a partial residual recorded below.

## Applied in this branch

- **P1** `.chezmoiscripts/00-tools/run_onchange_after_kitty.sh.tmpl:1` — the provisioner ran in chezmoi's `after_` phase while the distro package installers are `run_onchange_before_fedora.sh` / `run_onchange_before_ubuntu.sh`. Phase outranks the directory number, so on a fresh desktop host the installers would finish without installing kitty and a failed download would leave no terminal at all (R7). Fixed by renaming the provisioner to `run_onchange_before_kitty.sh.tmpl`, recording the reason in its header and in the plan's KTD-2, and updating every reference.
- **P2** `.ci/test-kitty-provisioning.sh:112-122` — the gate checks only counted ignore-path lines. Hardened to assert block membership: the provisioner's first entry must sit inside the OS/desktop gate, and both paths must appear inside the container-fact block. Verified by perturbation (moving a line out of its block fails the test).

## Residual Review Findings

- **P2** `.ci/test-kitty-provisioning.sh:112` — the gate **predicates** are still not evaluated. The test proves the kitty paths sit inside the correct gated blocks, but it does not render `.chezmoiignore` against forged desktop/container fact sets, so a change to a predicate's logic (rather than to the path lines) could still deploy the provisioner on a headless or container host without failing CI. Closing this needs a fact-cache-forging harness that no `.ci/` script builds today; it would be reusable across the other desktop-gated entries. No tracker sink was configured for this run, so this file is the durable record.

Not deferred, stated for completeness: the reviewer confirmed the release-lock selector, failure handling, gating implementation, and repository conventions clean, and confirmed R1–R6 and R8–R17 satisfied by the diff, with R2 and R13 intentionally dependent on the documented one-time manual distro uninstall.
