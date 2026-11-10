---
title: Verify a Linux-only Nix check's text inputs on macOS through nix derivation show
date: "2026-10-16"
last_updated: "2026-10-26"
category: best-practices
module: "Nix flake checks (local verification on macOS)"
problem_type: best_practice
component: testing_framework
severity: low
applies_when:
  - "Changing a check that exists only under checks.x86_64-linux while working on the macOS host, which has no Linux builder"
  - "The check compares files built with pkgs.writeText or another text-file builder, such as an expected declaration against a rendered one"
  - "Mutation-testing such a check locally before CI builds it"
  - "The check greps or runs a fetched upstream artifact, such as a pinned Linux release tarball from packages/t3code-release.json (as the former t3code-antigravity-layout check did)"
  - "The check's assertions live in its builder script and read text derivations, plus built paths the script can be pointed away from, as the former agent-instructions builder script did before moving to Python"
tags: ["mutation-testing", "fetched-artifact", "t3code", "prefetch-file", "flake-checks", "macos", "aarch64-darwin", "linux-builder", "derivation-show", "structured-attrs", "write-text", "verification", "agent-instructions", "builder-script", "build-command"]
related_components:
  - tooling
retire_when: "The macOS host gains a Linux builder (a nix-darwin linux-builder or a remote builder), so the check builds locally"
---

# Verify a Linux-only Nix check's text inputs on macOS through nix derivation show

## Context

Many repository checks exist only under `checks.x86_64-linux`, such as `t3code-traits`, which runs `cmp -s` between an expected JSON declaration and the one a fixture host's activation hands to `scripts/agent-settings` (the `cmp -s "$declared" "$want"` line in `tests/t3code-traits.nix`). The macOS host has no Linux builder, so `nix build .#checks.x86_64-linux.t3code-traits` cannot run there, and waiting for CI to learn whether a test edit goes red and then green makes mutation testing slow. Issue #224 changed both the module and that check from the Mac.

## Guidance

Evaluation is platform-independent, so the check's derivation graph is available on macOS even though it cannot be built there. A text file built with `pkgs.writeText` carries its whole content in its derivation, under `structuredAttrs.text` in `nix derivation show` output. Compare those strings directly:

```python
import json, subprocess, sys

drv = subprocess.check_output(
    ["nix", "eval", "--raw", ".#checks.x86_64-linux.t3code-traits.drvPath"], text=True
).strip()
graph = json.loads(subprocess.check_output(["nix", "derivation", "show", "-r", drv], text=True))
graph = graph.get("derivations", graph)

def text(fragment):
    names = [k for k in graph if k.endswith(fragment + ".drv")]
    if len(names) != 1:
        sys.exit("expected one derivation for {}, found {}".format(fragment, names))
    return graph[names[0]]["structuredAttrs"]["text"]

ok = True
for kind in ("settings", "client-settings"):
    same = text("t3code-expected-" + kind + ".json") == text("t3code-declared-" + kind + ".json")
    ok &= same
    print(kind, "match" if same else "MISMATCH")
sys.exit(0 if ok else 1)
```

`nix derivation show -r` walks every input of the check, so the declared file appears even though it reaches the check only through the fixture host's activation script. Match on the derivation name, and fail when a name matches zero or several derivations rather than picking one.

## Why This Matters

With this, the red-green loop and each mutation run locally in seconds. For issue #224, updating the expectation first produced a MISMATCH, the module change turned both files to `match`, and three mutations (the key back in `settings`, an empty `retiredKeys`, no `inherit remove`) each produced a MISMATCH again.

For `t3code-traits` this is a check of the inputs, not of the check. The comparison never runs the check's shell logic: the activation exercise, the merger's exit status, or the `cmp` itself. A mutation that breaks only that logic passes here. CI's `check-shards` build stays the evidence for the check as a whole, and a report should say which of the two produced each result.

## When to Apply

- The check's assertion reduces to equality or content of text files the graph already holds.
- You are on the macOS host and need red-green or mutation evidence before pushing.

It does not apply to a check whose inputs are built outputs rather than text derivations, such as a host closure. Two exceptions follow: a check whose builder script reads text derivations and built paths it can be pointed away from, so the script can run locally, and a fetched upstream artifact.

## Current agent-instructions check

The current `agent-instructions` check uses `tests/agent-instructions.py`. Run its local content checks and self-tests with:

```sh
python3 tests/agent-instructions.py home/h82/agents/instructions/instructions.md.tmpl
```

This command proves the Python content checks and self-tests only. The Nix `agent-instructions` check proves materialized delivery, independent rendering-to-delivery comparison, host recipient behavior, and Git/config guards.

## Historical builder-script replay (obsolete since 2026-10-24)

The following recipe and results describe the former `agent-instructions` test implementation and are retained as a historical record; do not use them as current verification instructions.

## A check whose assertions live in its builder script

`agent-instructions` (`tests/agent-instructions.nix`) makes its sentence, section, order, heading, tilde, removed-term, and confined-term assertions inside the builder script of `agent-instructions-tests`, so comparing text derivations proves nothing about them. The script itself is in the graph, though: `nix derivation show -r` lists it as that derivation's `env.buildCommand`, and every file it reads is either an `expected-instructions-<harness>.md` built with `pkgs.writeText` or a delivery path under a host's `home-manager-files`, which the Mac cannot build. Each delivery path is followed a few lines later by `cmp -s "$file" <expected>`, so point it at that expected file and run the script with `bash`:

```python
import json, os, re, subprocess, sys, tempfile

repo = sys.argv[1]  # git+file:// URL of a committed copy, so mutations evaluate
drv = subprocess.check_output(
    ["nix", "eval", "--raw", repo + "#checks.x86_64-linux.agent-instructions.drvPath"], text=True
).strip()
graph = json.loads(subprocess.check_output(["nix", "derivation", "show", "-r", drv], text=True))
graph = graph.get("derivations", graph)
work = tempfile.mkdtemp()
local = {}
for name, d in graph.items():
    if re.search(r"-expected-instructions-[a-z-]+\.md\.drv$", name):
        out = os.path.basename(d["outputs"]["out"]["path"])  # the script names the output path
        local[out] = os.path.join(work, out)
        open(local[out], "w").write(d["structuredAttrs"]["text"])
tests = [k for k in graph if k.endswith("-agent-instructions-tests.drv")]
if len(tests) != 1:
    sys.exit("expected one agent-instructions-tests derivation, found %d" % len(tests))
script = re.sub(
    r"/nix/store/([a-z0-9]{32}-expected-instructions-[a-z-]+\.md)",
    lambda m: local[m.group(1)],
    graph[tests[0]]["env"]["buildCommand"],
)
lines = script.split("\n")
for i, line in enumerate(lines):
    if re.match(r"^file=/nix/store/[a-z0-9]{32}-home-manager-files/", line):
        for later in lines[i : i + 12]:
            m = re.search(r'cmp -s "\$file" (\S+);', later)
            if m:
                lines[i] = "file=" + m.group(1)
                break
path = os.path.join(work, "build.sh")
open(path, "w").write("\n".join(lines) + '\nexit "$failed"\n')
sys.exit(subprocess.run(["bash", path]).returncode)
```

The byte comparison becomes trivially equal, and the Git-signing assertion fails on every host because the Git config also lives in the unbuilt `home-manager-files`: on an unmodified tree the only output is four "Git on <host> does not sign with my.user.gpgKey" lines. Treat those as the baseline and read every other line as a real failure. Everything else runs for real against the expected text, which is the template with the check's literals substituted, so a template edit reaches it.

Run each mutation on a scratch copy built from `git ls-files -co --exclude-standard -z` piped through `tar`, then `git init` and one commit inside the copy, and pass its `git+file://` URL; never copy `.git` (see [a copied git worktree still writes the real index](copied-git-worktree-writes-the-real-index.md)). Three traps came up while verifying the T3 Code subagent rules this way on 2026-10-19:

- Name the local expected files after their output paths, hash included. A first version named them after their `.drv` files, so no output-path lookup matched and its fallback took the first expected file of each harness; every host was then compared against the fake-key fixture's text, and the run reported GPG-section failures that had nothing to do with the edit. Dropping the hash fails the same way, because the real-key and fake-key variants of a harness share the name `expected-instructions-<harness>.md`.
- A mutation that finds its target by a sentence opening can hit another section first. "- When the session lists T3 Code's delegation tools" opens three rules in `# Compound Engineering` before the rule in `# T3 Code`, so the mutation broke the wrong section and still turned the run red. Anchor the search after the section heading, and grep the output for the assertion message the mutation should trip, not just for a non-zero count.
- Several evaluations in parallel print `SQLite database ... is busy` warnings, which look like one extra error line. Rerun a clean tree alone before calling it dirty.

On the branch that added those rules (`feature/disable-harness-subagents`, unmerged as of this writing), the clean tree produced no line beyond the baseline. Eleven mutations each failed with their targeted message on all twelve host and rendering combinations: the check covers four hosts on `x86_64-linux` (the two NixOS outputs and the x86_64 fixture with its bootstrap twin) and three renderings, because OpenCode shares the Claude Code one across its sixteen delivery paths. The mutations restored the old rule, deleted a rule, negated a rule with "Do not" or "Never", added an unpinned sentence, swapped two rules, and added text above the first heading. That last one exposed a gap the same branch closed: text above the first top-level heading escaped every assertion, because `sectionSentences` starts outside any section and the heading assertion reads only the heading lines.

This runs the check's real assertions but not its build, so CI's `check-shards` build stays the evidence for the check as a whole.

## A check that reads a fetched upstream artifact

Historically, `t3code-antigravity-layout` in `flake.nix` grepped the pinned T3 Code CLI bundle (`${self.packages.${system}.t3code-cli}/libexec/t3code/t3`) for lines it depended on. The bundle is a fixed-output fetch, not a text derivation, so `nix derivation show` has nothing to compare. Any pinned Linux asset is still reachable from the Mac: `packages/t3code-release.json` names it (`t3-<version>-linux-x64.tar.gz`) and its hash, and `packages/t3code-cli.nix` builds the URL from the release tag. Fetch and unpack it into an empty directory, then run the check's own logic against the extracted `t3`:

```sh
dir=$(mktemp -d)
url=https://github.com/pingdotgg/t3code/releases/download/<tag>/t3-<version>-linux-x64.tar.gz
tar -xzf "$(nix store prefetch-file --json "$url" | jq -r .storePath)" -C "$dir"
bundle="$dir/t3-<version>-linux-x64/t3"
LC_ALL=C grep -aoF -- 'crypto.digest("SHA-256", new TextEncoder().encode(instanceId))' "$bundle"
```

Compare the hash `nix store prefetch-file` prints with the pinned one before trusting the result. `LC_ALL=C` matters on macOS: BSD `grep` and `sed` stop with "illegal byte sequence" on the bundle under a UTF-8 locale.

Write each pinned fragment by copying it out of that file, not from memory or from reading the source. While fixing issues #221 and #223, a fragment written as `const codexLaunchArgv = ...` matched neither the Linux asset nor the darwin package's bundle, which both declare the binding without `const`; the check would have failed on every CI build. Running the corrected fragments and `tests/t3code-codex-launch.py` against the extracted Linux bundle passed, and three mutations of the declared launch argument turned the script red. That script and the Codex fragments were later removed with Codex; the technique applies unchanged to the fragments the check pins today.

Like the text comparison above, this runs the check's logic by hand, so CI's `check-shards` build stays the evidence for the check as a whole.

## Examples

Without this, the only local evidence for a `checks.x86_64-linux` edit made on the Mac is `nix flake check --no-build --all-systems`, which proves the check still evaluates and nothing about whether it passes. With it, run the script before the module change (expect MISMATCH), after it (expect match), and once per mutation (expect MISMATCH), then restore the tree before committing.

## Related

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md): why each guard needs a mutation that breaks it.
- [Mutations that only break evaluation](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md): a mutation must reach the compared text, not just fail evaluation.
- [An unanchored grep fragment misses the argument that decides where a write lands](unanchored-grep-fragment-misses-destination-argument.md): how to choose a fragment once it matches the artifact.
- [Substring sentence checks pass a negated instruction](substring-sentence-check-passes-a-negated-instruction.md): the sentence-start rule the `agent-instructions` assertions enforce.
- [A copied git worktree still writes the real index](copied-git-worktree-writes-the-real-index.md): why mutation copies get their own `git init`.
- [A T3 Code setting declared in settings.json outranks every repository's t3.json](../integration-issues/t3code-settings-json-value-outranks-repository-t3-json.md): the change this technique verified.
