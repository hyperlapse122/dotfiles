---
title: "A help-text check stays green while a CLI sends the named repository to the wrong host"
date: 2026-10-21
category: best-practices
module: "Nix flake checks (tests/git-cli-repo-flags.nix)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A check guards an instruction or script that tells an agent which flags or environment variables select a host, repository, or account for a CLI"
  - "The check greps `--help` output or binary strings for those flags instead of running the prescribed command"
  - "The CLI resolves its target from the current Git checkout, a config file, or a default host when the flag is malformed or ignored"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - flake-checks
  - mutation-testing
  - gh
  - glab
  - offline-probe
  - green-while-red
---

# A help-text check stays green while a CLI sends the named repository to the wrong host

## Context

The shared agent instructions tell an agent how to name a repository to `gh` and `glab` when it works outside a checkout of that repository, such as in a temporary directory. The first version of `tests/git-cli-repo-flags.nix` asserted that the installed CLIs still offered what the rule named: it grepped `gh pr view --help`, `gh api --help`, `gh help environment`, `glab mr view --help`, and `glab api --help` for `--repo`, `--hostname`, and `GH_REPO`, and the glab binary for `GITLAB_REPO`. Every assertion passed, and mutation tests on the grep patterns failed as expected.

The rule was still wrong, and the check could not see it. Cross-model code review, then offline probes in this session, showed three routing behaviors of gh 2.102.0 and glab 1.114.0 that no help text states:

- glab reads a bare `HOST/OWNER/REPO` passed to `glab repo view` as the project path `HOST/OWNER/REPO` on `gitlab.com` unless `HOST` is already an authenticated config host. The request went to `Host: gitlab.com` for `/api/v4/projects/glab-test%2Einvalid%2Fgroup%2Fproj`.
- `glab repo clone` with a full URL argument and `glab repo delete` with a full URL argument or a full-URL `GITLAB_REPO` send their requests to `gitlab.com` without `GITLAB_HOST`. With `GITLAB_REPO=https://gitlab.invalid/group/project`, `glab repo delete --yes` sent `DELETE /api/v4/projects/group%2Fproject` to `Host: gitlab.com`, which would delete a same-named project there for an account logged in to gitlab.com.
- `gh api` fills `{owner}` and `{repo}` from `GH_REPO` but ignores its host; the request goes to `github.com` unless `--hostname` is passed.

A help-text grep proves a flag exists. It cannot prove the flag does what the instruction says it does.

## Guidance

Guard a CLI usage rule by running the exact prescribed command inside the network-less Nix build sandbox and asserting the request the CLI was about to send.

1. Turn on the CLI's request debug output, which both CLIs print before the connection fails: `GH_DEBUG=api` for gh and `GLAB_DEBUG_HTTP=1` for glab (`tests/git-cli-repo-flags.nix:73`).
2. Use hosts under the reserved `.invalid` zone, fake tokens (`GH_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITLAB_TOKEN`), and an empty `HOME`, so no real configuration or credential takes part and DNS fails inside the sandbox. Without a token, gh stops with `To get started with GitHub CLI, please run:  gh auth login` before building any request, so the fake token is required, not cosmetic.
3. Capture each run to a file, tolerating the nonzero exit the failed connection causes, and grep that file for the `Host:` header and the request path (`tests/git-cli-repo-flags.nix:86`, `:109-111`, `:125`).
4. Take the packages from each Home Manager user's `home.packages` by `pname` rather than from `pkgs`, so the check runs what the profile installs and fails when a user stops installing one (`tests/git-cli-repo-flags.nix:48-58`). Turn a missing package into a builder failure instead of interpolating `null`, per [unguarded derivation interpolation](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md).
5. Mutation-test with the wrong usage, not with a renamed grep pattern: give `glab repo view` a bare `HOST/OWNER/REPO`, drop `--hostname` from `gh api`, drop `GITLAB_HOST` from `glab repo delete`. Each must fail the check, naming the form.

A destructive command such as `glab repo delete --yes` is safe to probe this way only because the sandbox has no network; never run such a probe outside it.

## Why This Matters

An agent instruction that names the wrong form does damage silently: the command succeeds against a different server, or fails in a way the agent works around. Here the wrong form could have deleted a project on `gitlab.com`. The help-text check would have stayed green through every glab and gh upgrade, because each named flag kept existing. The request-level probe fails on the behavior the instruction depends on, so a CLI upgrade that changes routing turns the check red.

## When to Apply

- A rule, script, or wrapper relies on a CLI selecting a host, repository, organization, or account from flags, environment variables, or a positional argument.
- The CLI has a debug or dry-run mode that prints the request before sending it.
- Writing or reviewing a check whose assertions read documentation of behavior (help text, man pages, binary strings) rather than the behavior.

## Examples

Before, in the first version of the check, a help-text assertion that passed while glab routed to `gitlab.com`:

```sh
help glab-mr-view ${pkgs.glab}/bin/glab mr view --help
expect "$HOME/glab-mr-view" "$flag" "glab mr view --help does not list --repo"
```

After, the prescribed command itself, with the request it would send:

```sh
run glab-repo-delete env GITLAB_HOST="$glHost" GITLAB_REPO="$glUrl" "$glab" repo delete --yes
expect glab-repo-delete "Host: $glHost" "glab repo delete with GITLAB_HOST does not reach HOST"
```

Related: [mutation testing reveals decorative assertions](mutation-testing-reveals-decorative-nix-check-assertions.md), [checks that read an option value instead of the materialized output](nix-check-reads-option-value-not-materialized-output.md), [an unanchored grep fragment misses the destination argument](unanchored-grep-fragment-misses-destination-argument.md).
