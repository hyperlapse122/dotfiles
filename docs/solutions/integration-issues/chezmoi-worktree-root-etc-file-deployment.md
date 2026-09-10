---
title: Deploying a Root-Owned /etc File from an Orca Worktree Re-Runs Every onchange System Script
date: 2026-09-10
last_updated: 2026-09-10
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "a new root-owned /etc file that exists only in an Orca feature worktree is invisible to a plain chezmoi apply"
  - "chezmoi source-path run from inside the worktree prints the primary checkout, not the worktree"
  - "pointing chezmoi at the worktree with --source=<worktree> marks every source-reading run_onchange script as re-run on a live machine"
  - "merging origin/main into the feature branch does not reduce the count of pending run_onchange scripts"
root_cause: design_limitation
resolution_type: workflow_improvement
severity: medium
tags:
  - chezmoi
  - worktree
  - udev
  - execute-template
  - onchange
  - orca
---

# Deploying a Root-Owned /etc File from an Orca Worktree Re-Runs Every onchange System Script

## Problem

A new `/etc/udev/rules.d/60-stm32-dfu.rules` file lived only on a feature branch
checked out in an Orca worktree. A plain `chezmoi apply` there cannot deploy it,
because chezmoi's configured source is the primary checkout, not the worktree.
Pointing chezmoi at the worktree does deploy it — and also re-runs every other
source-reading `run_onchange` script on a live, already-provisioned machine.

## Symptoms

- `chezmoi source-path`, run from inside the worktree, prints the primary
  checkout path regardless of the working directory.
- `chezmoi apply` from the worktree does not see the new file at all.
- `chezmoi --source=<worktree> apply` marks every source-reading `run_onchange`
  script in `.chezmoiscripts/30-linux/` for a re-run — 10 of the 12
  `install-system-*` scripts (sudoers, sysctl, bluetooth, swap/hibernate, and
  more), plus standalone ones such as the LUKS/TPM2 script. The session observed
  roughly twenty pending scripts on one host.
- Merging `origin/main` into the feature branch leaves that count unchanged.

## What Didn't Work

- **Blaming a stale data file.** The first hypothesis was that a
  `.chezmoidata/releases.json` one commit behind, not the source-path switch, was
  driving the fingerprint changes. Merging `origin/main` was clean and touched
  exactly that file, 2 lines — and the pending-script count did not move. That
  result is what isolated the cause to the source path itself.
- **`chezmoi apply --source=<worktree>` on its own.** It works, but its blast
  radius is the whole host, for the sake of landing one file.

## Solution

Render only the script that owns the new file, and run that rendering directly:

```sh
chezmoi --source=<worktree> execute-template \
  < .chezmoiscripts/30-linux/run_onchange_after_install-system-16-udev.sh.tmpl \
  > /tmp/udev.sh
bash /tmp/udev.sh
```

`run_onchange_after_install-system-16-udev.sh.tmpl` is the declared owner of
`/etc/udev/rules.d` and `/etc/libinput` deployment — `system/README.md:90` and
`:103` list it as the script that installs udev rules and libinput quirks and
reloads udev, and the template's own glob at line 9 covers
`system/linux/etc/udev/rules.d/**`. This is not a bypass of the ownership model:
it is the same script `chezmoi apply --source=<worktree>` would run for this
file, without the other 9 source-reading `install-system-*` scripts — 14 counting
every source-reading `run_onchange` script in `30-linux` — whose only change is a
swapped path literal.

The rendered script keeps every guard the templated version has. The
`sudo-elevation-guard.sh.tmpl` ladder still resolves, the override and removal
gates against `.chezmoidata/system.yaml`'s `udev` block still apply, and the
script still ends with `udevadm control --reload`. Only `SRC_ROOT` now points at
the worktree, so `install -D -m 644 "$src" "$dst"` reads the new file from there.

**Read the rendered script before running it.** Its `REMOVED_PATHS` loop runs
`rm -f` under `sudo` over whatever `.chezmoidata/system.yaml`'s `udev.removed`
declares. That is root-privileged deletion driven by a manifest, so confirming
what it will touch is part of the practice, not an optional aside.

## Why This Works

`run_onchange_after_install-system-16-udev.sh.tmpl:2` captures the render-time
source path into a template variable:

```
{{ $sourceDir := .chezmoi.sourceDir -}}
```

and line 10 interpolates it into the rendered script body:

```
SRC_ROOT="{{ $sourceDir }}/system/linux"
```

chezmoi decides whether to re-run a `run_onchange_*` script by hashing the whole
rendered script and comparing it to the last run's hash —
`.chezmoitemplates/fingerprint.tmpl:7-8` states this directly. The `SRC_ROOT`
line is a plain literal in the script body, outside `fingerprint.tmpl`'s own
dependency block. Render the same script from a different `sourceDir` and only
that literal changes, but the rendered text differs, so its hash differs, so
chezmoi re-runs it.

`system/README.md:18-20` documents this as the pattern for the whole script
family, and `grep -rl 'chezmoi.sourceDir' .chezmoiscripts/` matches 48 script
templates. The re-run set is therefore a property of the source-path switch, not
of anything the change itself touched.

The exemptions confirm the mechanism. Two `install-system-*` scripts — the host
and network ones — deliberately carry no source-tree dependency and no
fingerprint block. Neither interpolates the source path, so both render
identically from any checkout and neither re-runs.

## Prevention

- Do not reach for `chezmoi apply --source=<worktree>` to land a single file on a
  provisioned host. Find the owning script and render only that one.
- Locate the owner by glob, not by guesswork: `system/README.md`'s table, or the
  glob in the script template itself, says which `run_onchange_after_*` script
  covers a given path.
- Read every rendered script before running it under `sudo`. These scripts carry
  manifest-driven deletion loops.
- When a fingerprint count does not respond to a data-file fix, suspect the
  rendered body rather than the data.

## Related Issues

- [sudo Re-Prompts Inside the expect pty and the MOK Import Never Runs](fedora-mok-import-sudo-prompt-inside-expect-pty.md)
  — the same practice of inspecting the exact execution environment and the
  rendered command before elevated execution.
- [Remove the NVIDIA Stack by Hand on a Pascal Hybrid Host Declared Integrated-Only](fedora-pascal-hybrid-integrated-only-stack-removal.md)
  — direct subsystem overlap: its `80-nvidia-integrated-only.rules` is deployed
  and gated by the same udev installer script.
