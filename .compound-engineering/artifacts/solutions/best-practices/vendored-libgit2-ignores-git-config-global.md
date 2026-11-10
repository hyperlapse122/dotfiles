---
title: "A tool vendoring libgit2 ignores GIT_CONFIG_GLOBAL that a fixture relies on"
date: 2026-09-25
category: best-practices
module: "Nix flake checks (git-trim Home Manager profile)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check or test fixture drives a compiled tool against a Home Manager- or dotfile-manager-rendered git config, rather than driving the git CLI directly"
  - "The tool under test is written in a language that vendors its own git implementation (e.g. Rust + libgit2-sys) instead of shelling out to the git binary"
  - "A fixture sets GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, or similar CLI-specific override environment variables to inject config into a sandboxed HOME, and assumes every git-touching command in that fixture honors them identically"
  - "Deciding, during mutation testing, whether removing the option under test (here trim.delete) should turn a check red"
root_cause: wrong_api
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - git-trim
  - libgit2
  - vendored-dependencies
  - global-git-config
  - flake-checks
  - mutation-testing
  - fixture-design
---

# A tool vendoring libgit2 ignores GIT_CONFIG_GLOBAL that a fixture relies on

## Context

`tests/git-trim.nix` guards `home/h82/dev/git.nix`'s branch-cleanup settings: `trim.delete = "merged-local"` and `trim.detach = false` (the `trim.*` settings in `home/h82/dev/git.nix`), which override git-trim's upstream defaults of `--delete merged:origin` (also deletes merged branches on the remote) and detaching a checkout whose merged branch it deletes. The check has to prove those settings actually reach the packaged `git-trim` binary, not just that the rendered config text contains the right string.

The natural fixture for "prove a rendered config file is honored" in this repository's checks is `GIT_CONFIG_GLOBAL=<rendered-file>` inside a sandboxed `HOME` — every other git-driven check here shells out to the real `git` binary, which has read that override since Git 2.32. Pointing it at the Home Manager output and running `git config --get trim.delete` through it would confirm the value round-trips.

It does not confirm what the check needs. `git-trim` 0.4.4 is a Rust binary that reads config through a vendored copy of libgit2 rather than through `git`:

```console
$ grep -ac GIT_CONFIG_GLOBAL /nix/store/.../git-trim-0.4.4/bin/git-trim
0
$ grep -ao XDG_CONFIG_HOME /nix/store/.../git-trim-0.4.4/bin/git-trim
XDG_CONFIG_HOME
$ grep -ao 'libgit2-sys-[0-9.+a-z]*' /nix/store/.../git-trim-0.4.4/bin/git-trim
libgit2-sys-0.14.2+1.5.1
```

`GIT_CONFIG_GLOBAL` never appears in the binary at all. A fixture built around it would have the fixture's own `git` CLI commands (setup, commits, pushes) see the rendered config while `git-trim` itself never does — the tool silently falls back to its compiled-in defaults, which is exactly `merged:origin`, the setting the check exists to rule out.

## Guidance

Before choosing how a fixture injects configuration into a tool under test, check which config-discovery mechanism that tool actually uses — `strings`/`grep` on the binary is enough, as above. Do not assume a CLI-specific override env var (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`) reaches every git-touching process in a fixture just because it reaches the git binary the fixture also calls.

`tests/git-trim.nix` installs the rendered config at the same path Home Manager writes it to on a real host, `$XDG_CONFIG_HOME/git/config`, inside a sandbox `HOME`:

```sh
work=$(mktemp -d)
export HOME=$work/home
export XDG_CONFIG_HOME=$HOME/.config
mkdir -p "$XDG_CONFIG_HOME/git"
cp "$gitConfig" "$XDG_CONFIG_HOME/git/config"
```

(the `export HOME`/`XDG_CONFIG_HOME` block in `tests/git-trim.nix`, with `gitConfig` sourced from `userConfig.xdg.configFile."git/config".source` in `assertEntry`). Both the vendored libgit2 inside `git-trim` and the real `git` binary discover global config by searching `~/.gitconfig` and `$XDG_CONFIG_HOME/git/config` — that lookup path is part of git's config-file *discovery* protocol, which libgit2 reimplements, unlike `GIT_CONFIG_GLOBAL`, which is a CLI-only environment override with no equivalent in libgit2's discovery code.

Where the fixture does need a CLI-only override, it scopes that override to what only the CLI reads. Commit signing only matters to the `git commit`/`git push` calls the fixture itself makes to build the test repository — `git-trim` never signs anything — so `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgSign GIT_CONFIG_VALUE_0=false` (the `GIT_CONFIG_COUNT` line in `tests/git-trim.nix`) is safe precisely because nothing that reads it needs to also be visible to the binary under test.

The check also never passes the setting under test on the command line — it invokes `"$trim" --no-confirm` with no `--delete` flag (the `--no-confirm` call in `tests/git-trim.nix`), so `trim.delete`/`trim.detach` reach `git-trim` only through the file the fixture installed. A `--delete merged-local` flag on that invocation would make the check pass regardless of what `home/h82/dev/git.nix` declares, turning the guard decorative in exactly the sense `.compound-engineering/artifacts/solutions/best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md` describes, and mutation testing (deleting the `trim.delete` line) would not be able to tell the check apart from a broken one.

## Why This Matters

A fixture that reads correctly through the git CLI but not through the tool under test produces a misleading failure: the check goes **red on the config that is actually correct**. Nothing about the failure output points at the fixture — it looks exactly like the setting was never applied. Diagnosing it requires noticing that the tool under test is not `git` itself, then checking what config-discovery mechanism the tool's own dependency tree implements, which is not visible from the tool's CLI, man page, or even most of its source unless you check what version of its git library it vendors.

The trap has a second edge. Once the check is failing "for no reason," the fix that first suggests itself — pass the setting explicitly on the command line the fixture invokes — makes the check pass again, but it now proves nothing: the check would pass identically whether `home/h82/dev/git.nix` set `trim.delete` correctly, incorrectly, or not at all, because the flag overrides the config file either way. This is why proof-first verification matters here: the two proof-first runs used to develop this check were a red run with the `git-trim` package present but `trim.delete` absent (upstream default `merged:origin` deleted the merged branch on origin) and a green run with `trim.delete = "merged-local"` installed at the `XDG_CONFIG_HOME` path — both without a `--delete` flag on the invocation. Two independent reviewers of the check's design caught the `GIT_CONFIG_GLOBAL` plan from the binary's `strings` output before any of this was implemented, which is the check described above.

## When to Apply

- Any fixture for a check that exercises a non-git binary through git configuration — a merge tool, a commit hook runner, a branch-cleanup tool like `git-trim`, a git credential helper — where the binary is not `/nix/store/.../bin/git` itself.
- Any time a fixture's plan is "point `GIT_CONFIG_GLOBAL` (or another CLI env override) at the rendered config," before implementing it: run `grep -ac GIT_CONFIG_GLOBAL <binary>` (or the relevant override name) against the actual binary the check will invoke. A `0` means the fixture needs the on-disk path (`~/.gitconfig` or `$XDG_CONFIG_HOME/git/config`) instead.
- Any check whose invocation of the tool under test could plausibly take the setting under test as a CLI flag. If a flag would make the tool's behavior match the check's assertions independent of the rendered config, the check must not pass that flag — verify by mutation-testing removal of the option (here, deleting `trim.delete` from `home/h82/dev/git.nix` and confirming `nix build --no-link .#checks.x86_64-linux.git-trim` goes red).
- Not every CLI-only override is unsafe to use: one that only needs to affect commands the fixture itself runs directly (`GIT_CONFIG_COUNT` disabling commit signing for the fixture's own `git commit`/`git push` calls, the `GIT_CONFIG_COUNT` line in `tests/git-trim.nix`) is fine, because nothing that needs to see it is a different binary.

## Examples

Checking a candidate binary before writing the fixture:

```sh
grep -ac GIT_CONFIG_GLOBAL "$(dirname "$(readlink -f "$(command -v git-trim)")")/git-trim"
# 0 -> the tool never reads this override; find its real config-discovery path instead
grep -ao XDG_CONFIG_HOME "$trim_binary"      # confirms it does search here
grep -ao 'libgit2-sys-[0-9.+a-z]*' "$trim_binary"   # names the vendored dependency to check upstream
```

Mutation rounds that separate a real guard from a decorative one (`nix build --no-link .#checks.x86_64-linux.git-trim`):

| Mutation | Result |
| --- | --- |
| `trim.delete` removed from `home/h82/dev/git.nix` | red: `merged branch 'feature' was deleted on origin` |
| `trim.detach` removed | red: linked worktree HEAD rewritten |
| `trim.confirm = false` added | red: `trim.confirm turns off the deletion prompt` |
| `git-trim` package removed from `home.packages` | red: `git-trim is not in home.path` |

A related trap when a check's per-host logic is a subshell function, as `checkHost` is here (defined in `tests/git-trim.nix`): a subshell invoked as the left operand of `||` runs with `errexit` disabled inside it, so a fallback on the right never fires for a failure inside the subshell that the subshell itself doesn't explicitly `exit` on:

```sh
$ bash -c 'set -eu; f() ( false; echo continued ); f || echo fallback'
continued
```

Only `continued` prints; `fallback` never does, because `false`'s failure doesn't abort the subshell under a disabled `set -e`, and the subshell's own exit status comes from the final `echo`. A check that wraps a `checkHost`-style subshell call in `checkHost ... || echo "setup failed"` to report a distinct message on early exit should not rely on that pattern to detect failures raised inside the subshell body; the subshell must set its own exit status or fail file entry explicitly, the way `git-trim.nix`'s `checkHost` already does with `fail()` appending to `$failures` (in `checkHost`, `tests/git-trim.nix`) rather than relying on the caller's `||`.

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the same failure shape (a check that cannot go red on the property it names), reached here via a CLI-flag override instead of an always-true condition.
- [A check that reads an option value instead of the materialized output](nix-check-reads-option-value-not-materialized-output.md) — a related caution against proxies: there the proxy is a sibling option, here it is a fixture mechanism (an env var) that does not reach the binary the check is actually about.
- [An unset init.defaultBranch leaves a bare repo's HEAD dangling for a second clone](unset-defaultbranch-leaves-bare-repo-head-dangling-for-second-clone.md) — the same meta-lesson from the same test family: a sandboxed environment silently lacks ambient configuration (there, gitconfig defaults a developer shell supplies; here, a CLI-only env override a vendored library never reads).

## Out of scope

Issue hyperlapse122/nix-config#70 tracks the git-trim feature this check guards; whether upstream git-trim adopts `GIT_CONFIG_GLOBAL` support in a future release is outside this repository's control and would need re-verifying against that release's binary with the same `strings`/`grep` check before relaxing the fixture.
