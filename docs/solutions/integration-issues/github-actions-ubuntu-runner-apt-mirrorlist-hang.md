---
title: Ubuntu runner apt hangs on a dead mirrorlist entry
date: 2026-08-19
category: integration-issues
module: ci
problem_type: integration_issue
component: infrastructure
symptoms:
  - "`tmux Kitty image passthrough` and `omp zsh completion install` ran until a timeout killed them"
  - Only the jobs that install apt packages hung; every other job passed in seconds
  - "`gh run view --log` refuses to return logs while a run is in progress, so a hung job is undiagnosable"
  - The same commit ran the entire CI suite twice, tripling runner contention
root_cause: config_error
resolution_type: config_change
severity: high
related_components:
  - development_workflow
  - tooling
tags:
  - ci
  - github-actions
  - apt
  - ubuntu-runner
  - mirrorlist
  - timeout
  - concurrency
---

# Ubuntu runner apt hangs on a dead mirrorlist entry

## Problem

GitHub Actions jobs that install apt packages stalled for minutes instead of seconds. On branch `refactor/omp-delegation-first-model-tiers` (PR #258), three Ubuntu jobs ran until a cap killed them: `tmux Kitty image passthrough` (10 minutes), `omp zsh completion install` (over 10 minutes), and `Rust crate (crates/mxm4-haptic/, ubuntu-latest)` (15 minutes 15 seconds). Before this fix only one of seven jobs declared `timeout-minutes`, so an unbounded job would have ground toward GitHub's 6-hour default.

## Symptoms

- Jobs that use apt hung. Jobs that use `curl` or `cargo` did not.
- In the Rust matrix, the `macos-26` leg passed while the `ubuntu-latest` leg hung. That leg installs `libudev-dev` and `pkg-config`.
- `gh run view --log` and `--log-failed` both refuse while the run is in progress, so the hung job withheld the evidence needed to diagnose it.
- Every push to a PR branch started two full CI runs against the same commit.

## What Didn't Work

- **Blaming runner contention.** `ci.yml` declared both `on: push` and `on: pull_request` with no `concurrency` group, so each PR commit ran all seven jobs twice. Deduplicating the runs was correct on its own merits, but it did not fix the stall: a single uncontended run still drove both jobs into their caps.
- **Rewriting the apt sources files.** Substituting the mirror host in `/etc/apt/sources.list` and `/etc/apt/sources.list.d/ubuntu.sources` changed nothing, because the image does not name the mirror there. The job died at the apt timeout again.
- **Reading a 74-minute run on `main` as the same failure.** That run (`32210410799`) reported success after 1h14m, which is what first suggested a pre-existing hang. Its apt jobs actually finished in 17 and 18 seconds once they started, 73 minutes after the run was created; that run was waiting for runners. Two different causes produce the same symptom when jobs are unbounded, which is the real lesson of that run.

## Solution

Route every apt call through `.ci/lib/apt-install.sh` and bound the workflow.

The helper's contract is `apt-install.sh COMMAND|- PACKAGE [PACKAGE...]`. `COMMAND` is a binary whose presence proves the install is unnecessary; `-` skips that probe for a library package with no binary to test.

Drop the dead host from the mirrorlist, and never leave the list empty:

```bash
mirrorlist=/etc/apt/apt-mirrors.txt
if [ -f "$mirrorlist" ]; then
  sudo sed -i '/azure\.archive\.ubuntu\.com/d' "$mirrorlist"
  grep -q '://' "$mirrorlist" ||
    printf 'https://archive.ubuntu.com/ubuntu/\n' | sudo tee "$mirrorlist" >/dev/null
fi
```

Skip the network when the tool is already there, and bound what remains:

```bash
if [ "$command_name" != '-' ] && command -v "$command_name" >/dev/null; then
  printf 'apt-install: %s already present; skipping apt\n' "$command_name"
  exit 0
fi

sudo timeout 180 apt-get update -o Acquire::Retries=3
sudo timeout 180 env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends -o Acquire::Retries=3 "$@"
```

The three call sites are `apt-install.sh tmux tmux`, `apt-install.sh zsh zsh`, and `apt-install.sh - libudev-dev pkg-config`. The Rust job sets a `defaults.run.working-directory`, so its step also sets `working-directory: ${{ github.workspace }}`; a bare relative path would not resolve there.

Bound and deduplicate the workflow, matching the pattern `render-dotfiles.yml` already used:

```yaml
on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

Every job now declares `timeout-minutes` (10 to 20, sized against observed durations).

Verified by run `32237882640`: all 8 jobs green in 3 minutes 57 seconds. The tmux job fell from a 10-minute wedge to 9 seconds, `omp zsh completion install` to 18 seconds, and the Ubuntu Rust leg to 1 minute 18 seconds. One run per commit replaced two. The mirrorlist rewrite was tested locally against three fixtures: azure plus a working fallback, azure as the only entry, and no azure entry.

The probe also settled which tools the image ships: `tmux` is preinstalled, so its guard short-circuits, and `zsh` is not.

This fix is on PR #258 and is not merged, so `main` still carries the flake.

## Why This Works

Azure-hosted Ubuntu runners select their package mirror through a mirrorlist file rather than the sources files. Its first entry was unreachable:

```text
Get:1 file:/etc/apt/apt-mirrors.txt Mirrorlist [144 B]
Ign:2 http://azure.archive.ubuntu.com/ubuntu noble InRelease
Ign:3 http://azure.archive.ubuntu.com/ubuntu noble-updates InRelease
Hit:2 https://archive.ubuntu.com/ubuntu noble InRelease
Get:3 https://archive.ubuntu.com/ubuntu noble-updates InRelease [126 kB]
```

apt does recover on its own, which is why nothing failed outright. Each attempt against the dead host cost roughly 30 seconds before the fallback answered, and the pattern repeated for each index group, so `apt-get update` alone outlasted its bound. Deleting the entry removes the retry cycle rather than waiting it out, and the canonical mirror answers immediately.

The `Ign` lines also explain why the sources-file edit failed. `file:/etc/apt/apt-mirrors.txt` is the source of the URL, so editing the sources left the dead host in play.

## Prevention

- Give every CI job a `timeout-minutes`. It is an observability control before it is a cost control: an unbounded job hides its own logs for as long as it hangs, and it makes a queueing delay indistinguishable from a wedge.
- When a package install hangs on a hosted runner, read the mirrorlist before the sources files. `Get:1 file:/etc/apt/apt-mirrors.txt Mirrorlist` in the log is the tell.
- Probe for the binary before installing it. Hosted images preinstall more than expected, and the probe converts a network dependency into a no-op.
- Pair `on: push` scoped to the default branch with `on: pull_request` and a `concurrency` group. Without it, every PR commit runs the suite twice against the same SHA.
- Suspect the shared dependency when failures partition cleanly. Here the split was exactly apt versus no apt, and one matrix leg passing while its sibling hung located the cause faster than reading either test.

## Related Issues

- `docs/plans/2026-08-19-1401-refactor-omp-delegation-first-model-tiers-plan.md` — the work whose CI watch surfaced this flake.
- `docs/plans/2026-07-29-006-fix-tmux-kitty-image-passthrough-plan.md` — the plan that added the tmux job.
- `.ci/lib/apt-install.sh` — the helper; `.github/workflows/ci.yml` — its call sites and the bounds.
- `.github/workflows/render-dotfiles.yml` — the sibling workflow whose trigger and concurrency pattern was copied.
- No GitHub issue tracks this failure; it was found and fixed inside PR #258.
