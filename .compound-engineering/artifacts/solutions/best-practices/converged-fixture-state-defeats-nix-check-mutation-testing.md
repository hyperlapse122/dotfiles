---
title: "A fixture that starts two sources equal cannot prove which one a check reads"
date: "2026-09-21"
category: best-practices
module: NixOS flake checks (nr rebuild helper)
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A code path chooses its input from one of several similar sources — files, symlinks, environment variables, table rows — depending on a branch elsewhere in the same run"
  - "A test fixture models those sources as separate files or variables but seeds them from the same starting value"
  - "Mutation-testing a check whose assertion is sound and whose mutation does reach it, to confirm the fixture itself can tell the correct implementation from the bug"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - fixture-design
  - bash
  - symlinks
---

# A fixture that starts two sources equal cannot prove which one a check reads

## Context

`scripts/nr` is the flake's rebuild helper, packaged by `packages/nix-tools.nix` and aliased in `home/h82/shell/shell.nix` as `nrs`/`nrb`/`nrt`/`nrd`. It shells out to `nixos-rebuild`, then reports the generation change with `nvd`.

`nixos-rebuild boot` does not activate: the new generation lands in `/nix/var/nix/profiles/system` while `/run/current-system` keeps pointing at the running one until reboot. `switch` and `test` do activate, so for them `/run/current-system` is the symlink that moves. `scripts/nr` therefore picks a per-subcommand comparison target:

```sh
# boot does not activate, so its new generation lands in the system profile
# while /run/current-system still points at the running one.
if [[ $subcommand == boot ]]; then
  diff_target=$PROFILE
else
  diff_target=$CURRENT
fi
```

(`scripts/nr:119-125`)

A code reviewer found that the "before" sample had not been updated to match: it read `/run/current-system` unconditionally while "after" read `diff_target`. For `switch` and `test` those are the same path, so the bug was invisible there; for `boot` it compared two different symlinks and reported a wrong diff. The corrected script samples the same path on both sides:

```sh
before=$(readlink -f "$diff_target")
sudo -v
"${cmd[@]}"
after=$(readlink -f "$diff_target")
```

(`scripts/nr:138-141`)

`tests/nr.sh` is driven directly as `bash tests/nr.sh scripts/nr` and also wired into the flake as the `nr` check, which copies both files into a sandbox and runs the same command.

## The practice

**When a fixture is meant to prove a check reads the right one of several similar sources, seed those sources with different values.** A fixture that starts them equal cannot distinguish "the code read the source I intended" from "the code read some other source that happens to hold the same value right now." The assertion can be sound and the mutation can reach it, and the round still passes for the wrong reason.

## Where the first fixture failed

`tests/nr.sh` has a `reset_generations` helper that points both fixture symlinks at the same starting generation before the stub rebuild moves one of them:

```sh
reset_generations() {
  ln -sfn "$scratch/genA" "$scratch/current"
  ln -sfn "$scratch/genA" "$scratch/profile"
  rm -f "$scratch/nvd.log"
}
```

(`tests/nr.sh:185-189`)

That shape is correct for `switch`: only `/run/current-system` ever moves for that subcommand, so starting both links at `genA` and asserting the stub's move to `genB` really does test the code's choice of `diff_target`.

The `boot` case was first written against the same shape: both links start at `genA`, the stub moves the profile link to `genB`, and the test asserts `nvd` was called with `genA genB`. That version passed. Mutation-testing it by reintroducing the original bug — `before=$(readlink -f "$CURRENT")` — *also* passed.

With both links starting at the same generation, the buggy "before" (`readlink -f "$CURRENT"`, which is `genA`) and the correct "before" (`readlink -f "$diff_target"`, which for `boot` is the profile link, also `genA`) produce the identical value. The mutation changed which file "before" was read from, but not what it read, so the observable pair — `genA genB` — was the same either way. The assertion was sound and the mutation reached the code it targeted. The fixture simply could not tell the two implementations apart, because it never put `$CURRENT` and `$PROFILE` in different states.

## The fix: start from the state the real system is actually in

After a previous `boot`, the system profile is already ahead of `/run/current-system` — that divergence is the whole reason `boot` needs its own `diff_target`. The corrected fixture reproduces that starting state instead of the shared reset:

```sh
mkdir -p "$scratch/genC"
rm -f "$scratch/nvd.log"
ln -sfn "$scratch/genA" "$scratch/current"
ln -sfn "$scratch/genB" "$scratch/profile"
printf '#!%s\nln -sfn "%s/genC" "%s/profile"\nexit 0\n' \
  "$(command -v bash)" "$scratch" "$scratch" >"$stub_dir/rebuild-stub"
chmod +x "$stub_dir/rebuild-stub"
PATH=$stub_dir:$PATH "$rendered_run" boot --flake-dir "$repo" --host testhost >/dev/null 2>&1
[[ -f $scratch/nvd.log ]] || fail 'nvd was not called after boot changed the system profile'
grep -q "$scratch/genB $scratch/genC" "$scratch/nvd.log" ||
  fail "boot did not diff the profile's own before and after: $(cat "$scratch/nvd.log")"
```

(`tests/nr.sh:206-221`)

With `current=genA` and `profile=genB` as the starting state, and the stub moving the profile to `genC`, the correct implementation reads before=`genB`, after=`genC`. The buggy implementation reads before=`genA`, after=`genC`. The two are now observably different pairs, so the assertion can tell them apart, and the failure message names the wrong pair the log actually recorded rather than just reporting a failure.

## What was verified

Five rounds, each `bash tests/nr.sh scripts/nr`:

| Round | Fixture | Tree | Result |
| --- | --- | --- | --- |
| 1. Baseline | same-generation (`genA`/`genA`) | fix in place | green |
| 2. Mutation | same-generation | `before=$(readlink -f "$CURRENT")` reintroduced | **green** — the false pass |
| 3. Fixture corrected | diverged (`genA`/`genB`, stub moves profile to `genC`) | fix in place | green |
| 4. Mutation reintroduced | diverged | same mutation, unchanged | **red** — `boot did not diff the profile's own before and after: nvd-called diff .../genA .../genC` |
| 5. Fix restored | diverged | fix in place | green |

In round 2 the assertion was sound and the mutation ran through the code the test targeted; the fixture alone hid the bug. Round 4 shows the same mutation, unchanged, going red the moment the fixture stops being able to hide it.

## How to apply

- Before trusting a fixture, ask what it would look like if the code read the *other* candidate source. If the fixture cannot produce a different answer for that case, it is not testing the choice — only that the code did something.
- Whenever a change makes a code path read one of several similar sources — a symlink among several, a file among several, an environment variable chosen by a flag, a row chosen by an id — seed each source with a distinct, recognizable value, and assert on which specific value came out.
- A shared fixture-reset helper is fine for the cases it was designed for. Before reusing it for a new case, check whether that case needs its sources to start equal, or whether — like `boot`, which compares one source to itself across the run — it needs to start already diverged.
- A green mutation round on a sound assertion the mutation clearly reaches is not evidence the check works. It is a candidate for exactly this failure, and the next question is what state the fixture started in.

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion-level case: the assertion could never fail, because `! grep …` is exempt from `set -e`. Here the assertion is sound and does fail on the real bug; the gap is upstream, in the fixture.
- [A mutation that only breaks Nix evaluation proves nothing about a check](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) — the closest sibling: there the mutation never reached the assertion, dying at evaluation. Here it reaches the assertion every time. Both are found by reading *why* a round passed or failed, never that it did.
- [Restrictive service umask blocks SOPS user secrets](../integration-issues/sops-service-umask-blocks-user-secrets.md) — a check that reached and passed while asserting a proxy (ownership and mode) for the real property. Here the assertion reads the real property directly; the gap is in the fixture's starting world-state.

Each of those breaks at a different point. This is a fourth: the assertion is sound, the mutation reaches it, the property is asserted directly — and the check still cannot distinguish correct from buggy, because the fixture put the two candidate sources in the same state before either ran.

## Out of scope

Verifying this needed no `nix build`, no VM, and no hardware; `bash tests/nr.sh scripts/nr` drives it against fixture symlinks. The same script runs unmodified as the `nr` flake check, so the nix-level guard and the direct invocation share this fixture and its fix.
