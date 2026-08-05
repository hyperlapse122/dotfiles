# Residual review findings — docs/confirm-external-repo-issue-filing

Source run: `lfg` pipeline for [issue #149](https://github.com/hyperlapse122/dotfiles/issues/149).
Reviewed commit: `b1e2fb3`. Change: three prose edits to `.chezmoitemplates/agents-instructions.tmpl`.

Review coverage: `ce-code-review mode:agent`, five personas — correctness,
project-standards, agent-native, security, adversarial. The cross-model
adversarial peer did **not** run: the omp host is un-attestable under the
skill's host-attestation step, so the in-process adversarial reviewer ran as the
sanctioned fallback. Independent-model corroboration is therefore absent for
this review; convergence below is across separately dispatched in-process
contexts only.

Every P0 and P1 except the one below was fixed in the reviewed commit.

## Residual Review Findings

- **P0 — `tracker-defer` fallback chain has no repository-management probe.**
  `lfg/references/tracker-defer.md:21,59,138` (upstream plugin cache).
  Converged independently across the security and adversarial lenses. The new
  precedence sentence at `.chezmoitemplates/agents-instructions.tmpl:50` is
  binding on the agent, but the skill procedure it races against is
  self-contained, explicitly silent in non-interactive mode, probes only tracker
  reachability, and defaults its filing target to the current repo. Not fixed
  here because that file lives in the read-only plugin cache and is not owned by
  this repository (plan KTD8). Mitigated in the surface this repo does own: the
  instruction core now names the exact runtime moment the check must be
  re-applied and denies a silent-filing skill instruction any bypass authority.
  Filed: https://github.com/hyperlapse122/dotfiles/issues/168

## Advisory observations (report-only, no action required)

- No CI or `.ci/` check asserts this template's content, so the prose
  `below`/`above` directional cross-references introduced by this change would
  break silently if a future edit reorders the paragraphs.
- The attended-path rule "no answer is not consent" states no turn or timeout
  semantics distinguishing "still waiting for the user" from "no answer, so
  decline". The file's existing STOP-and-ask convention covers this in practice.
- The gate's branch logic (managed / unmanaged+attended / unmanaged+unattended /
  probe-failed) is prose inside one long paragraph rather than an enumerated
  decision tree, matching the file's house style but leaving the fail-closed
  branch one clause deep inside a sentence about a different topic.

## Notes

- No `settled_decision_conflicts` were raised during implementation; the plan
  carried no `session-settled:`-labeled decisions.
- No `settled_conflict`-stamped findings were emitted by the review.
