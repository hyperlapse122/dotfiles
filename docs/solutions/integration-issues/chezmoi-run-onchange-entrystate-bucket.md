---
title: A run_onchange_ Script Re-Runs Only After entryState Is Deleted, Never scriptState
date: 2026-09-18
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "an operator-blocking skip message tells the operator to run chezmoi state delete-bucket --bucket=scriptState, and that command changes nothing"
  - "the onchange script does not run on the next apply after its blocking condition was cleared by hand"
  - "the skip record under ~/.local/state/chezmoi/skips/ survives and dotfiles-skips keeps reporting the host as unconverged"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags:
  - chezmoi
  - entrystate
  - scriptstate
  - run-onchange
  - operator-blocking
  - skip-framework
---

# A run_onchange_ Script Re-Runs Only After entryState Is Deleted, Never scriptState

## Problem

Every `operator-blocking` skip this repository renders told the operator to clear the condition and then run `chezmoi state delete-bucket --bucket=scriptState`. That command does not re-run a `run_onchange_` script, so the one documented way out of an operator-blocking skip was a no-op and the record could never be cleared by following it.

## Symptoms

- `chezmoi state delete-bucket --bucket=scriptState` followed by `chezmoi apply` leaves the `run_onchange_` script unexecuted.
- The skip record stays in `${XDG_STATE_HOME:-~/.local/state}/chezmoi/skips/` and `dotfiles-skips` keeps reporting the host, because an `operator-blocking` record is cleared only by the script's own success path and nothing re-runs the script.
- The same wrong bucket appeared in the recovery hint of `.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl:36`, whose build scripts are `run_onchange_` as well.

## What Didn't Work

- **Deleting `scriptState`.** The bucket name reads like "the state of scripts", but it holds `run_once_` history only. On this host `chezmoi state dump` shows its entries keyed by a content hash with `{name, runAt}` values, all of them `run_once_` scripts.
- **A plain `chezmoi apply` after clearing the blocker.** An `operator-blocking` condition is by definition one that no render-time probe observes (`.chezmoitemplates/skip.sh.tmpl`), so clearing it changes neither the rendered script nor its fingerprint, and the recorded entry still matches.
- **Trusting the documented command.** Issue #382 ("fix(skips): an operator-blocking record outlives the host converging", closed) already reasoned about an operator who "runs `chezmoi state delete-bucket --bucket=scriptState`, re-applies and fully converges" — the wrong command had been carried across the repository as an assumption, unverified.

## Solution

Name `entryState` in every onchange re-run hint, and add a CI gate so the wrong bucket cannot come back.

Measured on chezmoi v2.72.1 with a scratch source, destination and persistent state, on one `run_onchange_` script:

| Action | Did the script re-run on the next apply? |
|---|---|
| second `apply` with unchanged content | no |
| `state delete-bucket --bucket=scriptState`, then `apply` | no |
| `state delete-bucket --bucket=entryState`, then `apply` | yes |

The changed sites:

- `.chezmoitemplates/skip.sh.tmpl` — the `operator-blocking` message, which renders into every consumer of that direction.
- `.chezmoiscripts/70-agents/run_after_assert-orchestration-hook.sh.tmpl:36` — the `RECOVERY` hint.
- `AGENTS.md` — the skip-direction paragraph, which now states the mapping rather than only the command.
- `.ci/test-package-installer-verdict.sh` — two static gates: no rendered installer and no hint source (`skip.sh.tmpl`, the assert script, `AGENTS.md`) may name `--bucket=scriptState`.

Opened on branch `bugfix/installer-failure-policy` for issue #537 (commits `9fa60775` and `7cfe4a9f`); unmerged as of this writing.

## Why This Works

chezmoi keeps `run_onchange_` state per target in `entryState`: on this host `chezmoi state dump` shows `/home/<user>/.chezmoiscripts/30-components/80-devtools.sh` in that bucket with `{"contentsSHA256": "…", "type": "script"}`. An apply hashes the freshly rendered script and compares it with that record, which is the mechanism `AGENTS.md` describes when it says a clean exit-0 skip is recorded as successful and will not retry until a fingerprint changes. `scriptState` answers a different question — has this `run_once_` script ever run — so deleting it leaves the onchange comparison intact and the script skipped.

Deleting `entryState` drops those recorded digests, so the next apply treats every managed entry as new and runs the script. It is a blunt instrument by design: it re-runs every onchange script on the host, which is acceptable because each one is idempotent on a converged host.

## Prevention

- Match the bucket to the lifecycle: `run_once_` is `scriptState`, `run_onchange_` is `entryState`. A message that tells an operator how to re-run a script names the bucket its lifecycle uses.
- Keep the static gate. `.ci/test-package-installer-verdict.sh` fails when `--bucket=scriptState` reappears in a rendered installer or in one of the hint sources, which is what turns this from a fixed typo into a fixed rule.
- Verify a state command before documenting it. `chezmoi state dump` shows which bucket holds the record, and a scratch source plus `--persistent-state` proves what a delete actually re-runs, in under a minute.
- Treat a recovery instruction as code. This one was repeated across a template, an assertion script and the repository instructions for months without anyone running it.

## Related

- `docs/solutions/integration-issues/chezmoi-localarchive-overlay-entrystate-drift.md` — `entryState` from the file-drift side: an overlay of an archive-owned file makes the next apply abort.
- `docs/solutions/integration-issues/chezmoi-worktree-root-etc-file-deployment.md` — how rendered-content hashing decides onchange re-runs, and how a worktree source path cascades them.
- `docs/plans/2026-09-17-2131-fix-installer-failure-policy-plan.md` — the plan that carries this as KTD7 and R15, alongside the installer failure policy.
- `.chezmoitemplates/skip.sh.tmpl` — the declaration contract whose `operator-blocking` branch prints the re-run command.
