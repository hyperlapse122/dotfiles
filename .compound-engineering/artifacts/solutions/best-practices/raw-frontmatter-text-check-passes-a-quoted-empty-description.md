---
title: "A frontmatter check on raw text passes a quoted empty description"
date: 2026-10-23
category: best-practices
module: "Agent skill checks (tests/test-audit-skill.nix, tests/korean-skills.nix)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check reads a YAML frontmatter field such as a SKILL.md description with awk, sed, or grep and tests the extracted text"
  - "The consumer of that file, such as Codex or another harness, parses the YAML and rejects or drops an empty or null value"
  - "Mutation-testing a check whose input is a YAML scalar, to confirm every spelling of an empty value still turns it red"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - yaml
  - frontmatter
  - agent-skills
  - fail-open
  - decorative-assertions
---

# A frontmatter check on raw text passes a quoted empty description

## Context

`tests/test-audit-skill.nix` and `tests/korean-skills.nix` prove that every declared skill reaches each harness's skill root with a usable `SKILL.md`. One assertion pulls the frontmatter `description` out with awk and fails when it is empty:

```sh
description=$(awk '... /^description:/ { sub(/^description:[ ]*/, ""); print; exit }' "$dir/SKILL.md")
if [ -z "$description" ]; then
  echo "... declares no description" >&2
  failed=1
fi
```

The check turned red for a missing field and for `description:` with nothing after it, so it looked live. The cross-model review of the branch that added `test-audit` found the gap. With `description: ""` in the vendored `SKILL.md`, the unchanged check stayed green, while the pinned Codex 0.163.0 listed that skill zero times under `codex debug prompt-input`. Codex's parser fails a skill with `MissingField("description")` when the parsed value is empty (`codex-rs/skills/src/parser.rs` in the `openai/codex` repository at tag `rust-v0.163.0`, outside this tree), and the loader skips it. The guard was green while the skill was unavailable.

## Guidance

**Test the value the consumer parses, not the text the file holds.** YAML spells an empty or missing scalar several ways, and all of them survive a raw-text `[ -z ]`:

| Line in the file | Raw text after the key | YAML value |
| --- | --- | --- |
| `description: ""` | `""` | empty string |
| `description: ''` | `''` | empty string |
| `description: "  "` | `"  "` | whitespace only |
| `description: null` | `null` | null |
| `description: ~` | `~` | null |

The fix normalizes the extracted value before the emptiness test (`tests/test-audit-skill.nix:147-153`, `tests/korean-skills.nix:176-182`). It trims whitespace, strips one pair of surrounding double or single quotes, trims again, and treats `null`, `Null`, `NULL`, and `~` as empty:

```sh
description=$(printf '%s' "$description" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//')
case "$description" in
  "" | null | Null | NULL | "~") description= ;;
esac
```

That covers the spellings a hand-edited or generated `SKILL.md` produces. A full YAML parse would cover block scalars and escapes as well. When a check depends on those, parse the frontmatter with a real YAML library in the builder rather than widening the sed.

## Why This Matters

A skill-delivery check stands in for "the harness can load this skill". When it accepts a value the harness rejects, a broken skill ships with a green build. Nothing surfaces it until someone notices the skill is missing from a session. A rewrite or a generator that emits `description: ""`, or a template placeholder of `null`, is a realistic edit, not a contrived one.

This is the same fail-open family as [a nullable option that reaches a shell comparison as an empty word](nullable-option-empty-operand-passes-a-shell-comparison.md). A value reaches a shell test in a form the test misjudges. As with [a check that reads an option value instead of the materialized output](nix-check-reads-option-value-not-materialized-output.md), the check inspects a proxy instead of what the consumer actually reads.

## When to Apply

- Writing or reviewing any check that extracts a YAML, TOML, or JSON field with text tools and then asserts on it.
- Adding a new skill set to the skill checks: run the description mutations below against it.
- Bumping a harness pin whose skill parser rejects empty fields: the check must keep matching what that parser accepts.

## Examples

Mutation-test every spelling in the table, not only a removed line (`mutation-testing-reveals-decorative-nix-check-assertions.md`). In a scratch copy (`copied-git-worktree-writes-the-real-index.md`), each one must turn `test-audit-skill` red with "declares no description". The two this fix was proven against:

```text
description: ""      -> red after the fix, green before it
description: null    -> red after the fix
(line removed)       -> red before and after
```

`korean-skills` carries the same normalization. Its skill text comes from a pinned flake input, so mutate it by pointing a scratch copy's input at an edited checkout rather than by editing a file in this tree.

Edit the copy with an interpreter called by absolute path, not from inside the copy. In this session, a `cd` into the copy made the shimmed `python3` fail on the copy's untrusted `mise.toml`. The edit never landed, and every mutation read as "survived" until the edit ran by absolute path.
