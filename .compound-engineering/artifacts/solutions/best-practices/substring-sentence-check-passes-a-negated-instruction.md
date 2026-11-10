---
title: "A substring check for a required instruction sentence passes when the sentence is negated"
date: 2026-10-12
last_updated: "2026-10-24"
category: best-practices
module: "Agent instructions render check (tests/agent-instructions.nix)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check requires a sentence of agent instructions or other prose to be present with grep -F or another substring match"
  - "The guarded text is an imperative whose meaning flips when words are added in front of it, such as Do not or Never"
  - "Mutation-testing a prose check where the mutation list only deletes guarded sentences"
  - "A rule whose reversal could be added as a separate sentence beside the guarded one, which no required-sentence check can see"
  - "A pinned section whose sentences lean on their neighbours, such as one starting with This holds, or whose meaning changes when a sentence is repeated"
root_cause: logic_error
resolution_type: test_fix
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - grep
  - agent-instructions
  - sentence-order
---

# A substring check for a required instruction sentence passes when the sentence is negated

## Context

Historically, `tests/agent-instructions.nix` rendered the shared agent instructions for each harness and required a list of literal sentences in every rendered file. Until the first fix described here, its helper `requireSentences` tested each one with `grep -qF -- "$sentence" "$file"`. The check had been mutation-tested by deleting each guarded sentence, and every deletion turned it red.

While rewriting the `# Review findings` section (plan `.compound-engineering/artifacts/plans/2026-10-12-0908-feat-review-findings-override-plan.md`), a cross-model adversarial review ran a mutation the deletion rounds never tried: it prefixed the guarded coverage sentence with "Do not". Every assertion still passed for Claude Code, Antigravity, and Codex. The sentence was still a substring of the line, so the check stayed green while the rendered instruction now told agents the opposite of the rule. The same review found that the new stop for a fix that would reverse a user decision had no guard at all; deleting that bullet also left the check green.

A deletion round proves only that the check notices the text is gone. Prose instructions change meaning through additions as easily as through removal, and a substring match cannot see additions.

## Guidance

Match a required sentence only where a sentence begins, and add a negation round to the mutation list.

The historical Nix helper accepted a sentence only when it occurred exactly once in the file and the text before that occurrence was empty, a list marker (a hyphen and a space, optionally indented), or ended with the full stop and space of the previous sentence (`requireSentences` in `tests/agent-instructions.nix`):

```nix
requireSentences = message: sentences: ''
  for sentence in ${lib.escapeShellArgs sentences}; do
    if ! s="$sentence" awk '
      BEGIN { s = ENVIRON["s"] }
      {
        line = $0
        while ((i = index(line, s)) > 0) {
          pre = substr(line, 1, i - 1)
          n++
          if (pre == "" || pre ~ /^ *- $/ || pre ~ /\. $/) anchored++
          line = substr(line, i + length(s))
        }
      }
      END { exit !(n == 1 && anchored == 1) }
    ' "$file"; then
      echo ${esc message} "$sentence" >&2
      failed=1
    fi
  done
'';
```

Counting every occurrence also makes a doubled sentence fail, which the first version, which stopped at the first match on a line, could not see.

`index` is a fixed-string search, so backticks, `#`, `/`, and other punctuation in the sentences need no escaping. `awk -v` processes escape sequences in the values it assigns, so the helper passes the sentence through `ENVIRON`, which keeps a backslash such as the pinned `\~` intact; `sectionSentences` and the confined-terms filter pass their headings through `ENVIRON` for the same reason.

A sentence-start match still passes when the reversal is a separate sentence. Adding the Antigravity cross-model peer for issue #206, a cross-model adversarial review kept the pinned "also delegate that pass to Antigravity" sentence and added "Do not delegate the pass to Antigravity." after it. The pinned sentence still began where a sentence begins, so the check stayed green while the section now said both things. No list of forbidden phrases closes this, because a reversal can be worded any way.

The historical Nix check closed this with an allowlist over the section instead. The allowlist is necessary but not sufficient, as the order section below shows: every sentence in the named section that mentions the guarded subject must be one of the pinned sentences, and the section heading must exist, or the allowlist checks nothing (the helper lived in `tests/agent-instructions.nix` until 83002d4). The pinned subset is derived from the required list, so there is one list to maintain:

```nix
peerPattern = "Antigravity|Argon|OpenCode|opencode";
extraPeerSentences = lib.filter (
  sentence: builtins.match ".*(${peerPattern}).*" sentence != null
) delegationSentences;
```

`onlyPinnedSentences` takes the lines under `# Cross-model delegation` up to the next top-level heading, strips the list marker, splits sentences on a full stop followed by a space, keeps those matching `peerPattern` (`Antigravity|Argon|OpenCode|opencode`, widened when the OpenCode peer joined for issue #229), and fails on any that is not in the pinned list. The split assumes no guarded sentence contains a full stop followed by a space, such as "e.g. "; a sentence that did would be reported as unpinned, which fails red.

Membership in both directions still cannot see order or count. The `# Pull and merge requests` section is pinned whole: `onlyPinnedSentences` with pattern `.` checks that every sentence in it is pinned, and `sentencesInSection` checked that every pinned sentence is in it. Both are set checks. In the T3 Code PR watch work (plan `.compound-engineering/artifacts/plans/2026-10-15-1937-fix-t3-code-pr-watch-handoff-plan.md`), a cross-model adversarial review showed two edits that change meaning and pass both: repeating a pinned sentence, and moving "This holds when you babysit a request directly, through `ce-commit-push-pr`'s babysit handoff, and in `lfg` step 10." away from the sentence it qualifies. Moved after a different bullet, "This" binds to another rule.

For a section pinned whole, the historical Nix check compared the section's sentence stream to the pinned list in order, as `sentencesInOrder` did:

```nix
sentencesInOrder = message: heading: sentences: ''
  expected=$(mktemp)
  actual=$(mktemp)
  printf '%s\n' ${lib.escapeShellArgs sentences} > "$expected"
  h=${esc heading} awk '
    BEGIN { h = ENVIRON["h"] }
    $0 == h { inside = 1; next }
    /^# / { inside = 0 }
    inside { sub(/^- /, ""); gsub(/\. /, ".\n"); print }
  ' "$file" | grep -E -- . > "$actual" || true
  if ! cmp -s "$expected" "$actual"; then
    echo ${esc message} >&2
    diff "$expected" "$actual" >&2 || true
    failed=1
  fi
'';
```

The pinned list must then be written in section order, which also makes it read as the section does. `grep -E -- .` drops the blank lines the awk split leaves. The diff names the lines out of place.

Later, 83002d4 slimmed the instructions into one file and removed `onlyPinnedSentences`, `sentencesInSection`, and `sentencesInOrder`; a subsequent Nix implementation restored those helpers and related heading and removed-term inventories. Those Nix helpers and inventories were removed on 2026-10-24.

The current `content_problems` in `tests/agent-instructions.py` selects the `POLICIES` once and checks anchored occurrences, expected `HEADINGS`, and removed terms in `REMOVED`. Its self-tests cover deletion, negation, duplication, removed headings, and harmless prose edits; it is not a complete sentence allowlist. `delivery_problems` compares every materialized delivery with an independent render, while the Nix check verifies materialized delivery, recipient behavior, and Git/config guards.

When a rule has a safety stop, guard the stop as its own sentence. The review-findings rule tells autonomous runs to apply the recommended fix. Without a guarded sentence for the stop that protects user decisions, deleting the stop leaves the permissive half guarded and green.

## Why This Matters

A guard on agent instructions exists to catch an edit that changes what agents do. Negating an imperative is the smallest such edit, and a substring check accepts it. The failure is silent: the build stays green, and every rendered instruction file, such as `~/.claude/CLAUDE.md`, carries the inverted rule.

## When to Apply

- Any check that requires sentences of prose, not identifiers, to be present.
- Whenever a prose guard is mutation-tested: add one round that prefixes a guarded sentence with "Do not", and one that adds a reversal as a separate sentence and as a separate bullet, beside the deletion rounds.
- When a section's rules about one subject must not be contradicted, check that every sentence in the section naming that subject is pinned, not only that the pinned sentences are present.
- When a section is pinned whole and any sentence leans on a neighbour or a repeat would change it: check order and count, and add a move round and a duplicate round to the mutation list.
- When a rule pairs a permission with a limit on it, such as "apply the recommended fix" with "stop when it reverses a user decision": guard the limit too.

## Examples

The mutation runner used for this change applied each edit in a scratch copy built per `copied-git-worktree-writes-the-real-index.md`, then built `checks.x86_64-linux.agent-instructions`:

| Mutation | `grep -qF` helper | Sentence-start helper |
| --- | --- | --- |
| Delete the coverage sentence | red | red |
| Prefix the coverage sentence with "Do not" | green (missed) | red, 12 assertion lines |
| Delete the user-decision stop bullet | green (unguarded) | red after adding its sentence |

Twelve lines means three harnesses times four host generations: the NixOS host and its bootstrap twin, and the x86_64 fixture host and its twin.

The first version of the historical Nix helper checked only the first occurrence of a sentence on each line, so a line holding a negated copy before a real one was reported as missing. That error failed red, the safe direction. A later version counted every occurrence and failed the same line because the sentence appeared twice.

For the Antigravity peer, the same runner showed:

| Mutation | Sentence-start helper alone | With the section allowlist |
| --- | --- | --- |
| Add "Do not delegate the pass to Antigravity." after the pinned bullet's last sentence | green (missed) | red |
| Add a bullet "Never use Argon for a cross-model pass." | green (missed) | red |
| Rename the `# Cross-model delegation` heading | green | red, section missing |

For the T3 Code PR watch rules in `# Pull and merge requests`:

| Mutation | Membership helpers | With `sentencesInOrder` |
| --- | --- | --- |
| Move "This holds when ..." to the end of the section | green (missed) | red |
| Duplicate the `link_pull_request` bullet | green (missed) | red |
| Delete any one of the 13 new sentences | red | red |
| Add an unpinned contradicting bullet | red | red |

## Related

- `unanchored-grep-fragment-misses-destination-argument.md`: a `grep -F` fragment that omits the part carrying the claim still matches after the claim changes.
- `compound-condition-clause-assertions-miss-connective-mutations.md`: per-clause substring checks pass when the connective between clauses flips.
- `mutation-testing-reveals-decorative-nix-check-assertions.md`: text assertions fail in the direction of passing; mutate the check and require red.
