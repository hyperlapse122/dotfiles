---
title: ShellCheck SC2100 Can False-Positive on a Plain Hyphenated Bareword Assignment in a Large File
date: 2026-09-18
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: development_workflow
symptoms:
  - "the \"Shellcheck (rendered scripts + repo-meta)\" CI job fails on a line like `label=some-test-name` with \"SC2100 (warning): Use $((..)) for arithmetics, e.g. i=$((i - 2))\", even though the assignment is an identifier with hyphens, not an arithmetic expression"
  - "shellcheck run locally against the same few lines in isolation (a small reproduction snippet) does not reproduce the warning, only the full file does"
  - "some hyphenated bareword assignments in the same file trigger the warning and others, in the same syntactic shape, do not"
root_cause: third_party_tool_limitation
resolution_type: code_fix
severity: low
tags:
  - shellcheck
  - ci-gate
  - bash
  - static-analysis
  - false-positive
---

# ShellCheck SC2100 Can False-Positive on a Plain Hyphenated Bareword Assignment in a Large File

## Problem

This repository's `.github/workflows/render-dotfiles.yml` "Shellcheck (rendered scripts + repo-meta)" job (formerly in `.github/workflows/ci.yml`) lints every `.ci/*.sh` file directly (not only chezmoi's rendered installer output), with no `-S`/severity filter, so any shellcheck warning fails the job. Adding new `label=<hyphenated-name>` scenario assignments to `.ci/test-package-installer-verdict.sh` — the exact style the file's existing `devtools`/`apps` scenarios already use — produced `SC2100 (warning): Use $((..)) for arithmetics, e.g. i=$((i - 2))` on 14 of the new lines, none of which contain an arithmetic expression.

## Symptoms

- CI fails with `SC2100` pointing at an ordinary bareword assignment such as `label=flatpaks-fedora-install-fails`.
- A minimal reproduction — the flagged line plus a shebang, or a ~25-line slice of the file around it — does not reproduce the warning; only running shellcheck against the whole (~1000+ line) file does.
- Within the same file, some `label=<hyphenated-name>` lines (the pre-existing `devtools-fedora-install-fails` style, and some of the newly added `tailscale-*`/`podman-*` ones) never triggered it, while others (`flatpaks-*`, `desktop-ime-*`, `base-*`) did, with no syntactic difference between the flagged and unflagged lines.

## What Didn't Work

- **Reproducing in isolation to find the exact trigger.** A short snippet built from the flagged lines plus enough surrounding context did not reproduce the warning locally, which means the trigger depends on shellcheck's whole-file data-flow analysis (which variables it has seen assigned where) rather than anything visible in a local diff. Chasing the exact heuristic further was not worth the cost once quoting was confirmed to clear it everywhere it was tried.
- **Assuming `.ci/*.sh` files were shellcheck-exempt.** Earlier work on this same PR treated `.ci/test-package-installer-verdict.sh` as a harness that only shellchecks its own *rendered installer* output (`.ci/test-android-skill-ownership.sh`, `.ci/test-jetson-installer-render.sh`, and similar tests do exactly that, matching `shellcheck -S warning "$rendered"`). The CI workflow lints the harness scripts themselves too, as part of "repo-meta" scripts under `.ci/`; a purely local check of the rendered installer output that this repo's own installer-verdict test produces is not equivalent to what CI runs against the `.ci/*.sh` sources.

## Solution

Quote the assignment's right-hand side. shellcheck's own suggested fix for SC2100 is to use `$((..))` when arithmetic is intended; when it is not, wrapping the value in quotes removes the ambiguity shellcheck's parser is flagging:

```bash
# Flagged
label=flatpaks-fedora-install-fails

# Clean
label='flatpaks-fedora-install-fails'
```

All 24 of this PR's new `label=<name>` assignments (`tailscale`, `flatpaks`, `podman`, `desktop-ime`, `base` scenarios in `.ci/test-package-installer-verdict.sh`) were quoted uniformly, including the ones not currently flagged, since the trigger is not reliably predictable per line and this file's pre-existing `dotnet-*` scenarios already use single-quoted labels. Landed on branch `bugfix/remaining-installer-failure-policy` (issue #541).

## Why This Works

Quoting the value removes the syntactic shape (`identifier=identifier-identifier`, unquoted) that SC2100 pattern-matches against; a quoted string is unambiguously a string literal to shellcheck's parser regardless of what other variables the whole-file analysis has seen. This is a known false-positive class for SC2100 — the check exists to catch a real mistake (`i=i-1` meant as decrement), and a hyphenated identifier is one of the shapes it can misread the same way. The fix is the same either way: make the assignment unambiguous.

## Prevention

- **Quote a `label=<value>`-style bareword assignment whenever the value contains hyphens, in a file this large.** It costs nothing and pre-empts SC2100 regardless of whether shellcheck currently flags that specific line.
- **`.ci/*.sh` files are linted directly by CI's shellcheck job, not only the rendered installer output some of them produce.** Run `shellcheck --format=tty --external-sources <file>` against the actual `.ci/*.sh` source before assuming a harness script is exempt because it also shellchecks the installer output it renders into its own scratch directory.
- **Don't chase an exact SC2100 trigger across a large file.** A local reproduction that doesn't reproduce the warning is not proof the CI finding is wrong; shellcheck's data-flow analysis is whole-file. Quoting is a cheap, reliable fix that doesn't require understanding why only some lines were flagged.

## Related

- `docs/solutions/integration-issues/helper-return-0-with-no-other-return-reads-as-abandoned-skip-step.md` — a different false-positive-shaped CI finding from the same PR, in this repo's own custom `check-skip-declarations.sh` checker rather than shellcheck.
- `.ci/test-package-installer-verdict.sh` — the file with the quoted scenario labels.
- `.github/workflows/render-dotfiles.yml` — the "Shellcheck (rendered scripts + repo-meta)" job that lints `.ci/*.sh` directly (moved from `.github/workflows/ci.yml`).
