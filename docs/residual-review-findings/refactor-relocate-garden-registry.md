# Residual Review Findings — refactor/relocate-garden-registry

Source run: `ce-code-review mode:agent plan:docs/plans/2026-07-30-002-refactor-relocate-garden-registry-plan.md`, 8 reviewers (correctness, security, adversarial, project-standards, testing, maintainability, agent-native, reliability). Applied fixes landed in `fix(review): close silent-pass paths in the garden gate`. No tracker tickets were filed: the repository instructions prohibit the agent from creating issues, so this committed record is the durable sink.

## Decision gate — not applied, needs a human call

- **P2 · `dot_local/bin/executable_src-audit:24` · `~/src`-absent early exit can silently skip the registered root-external tree.** *(reliability + agent-native, independent agreement, confidence 75)*
  `src-audit` exits 0 with "nothing to audit" purely on `~/src` being absent, before consulting the registry. Before this change that gate was safe, because the registry itself lived inside `~/src`, so an absent `~/src` implied nothing had been provisioned. The relocation breaks that equivalence: the registry now deploys to `~/.config/garden/garden.yaml` independently of `~/src`, and `~/src` is created only later by `garden grow` in the last after-script. On a host where `~/src` does not yet exist, a broken `~/.local/share/chezmoi` tree is reported as "nothing to audit" instead of `broken` — so R16's promised coverage of the root-external tree does not hold in that state, while `AGENTS.md` now tells agents the checkout "receives the same `src-audit` coverage ... as every other project."
  Not applied deliberately: the plan's U3 pinned this early exit ("감사는 읽기 전용이므로 루트를 만들 이유가 없다"), and changing the audit's exit contract is a design decision, not a mechanical fix. Two candidate resolutions: have the guard consult the registry for root-external trees before reporting nothing to audit, or narrow the `AGENTS.md` coverage claim to in-root trees. Either is a contract change the owner should choose.

## Residual risks

- **Plan defect found during implementation.** The plan's Definition of Done requires the old target literal `src/garden.yaml` to appear zero times repo-wide. That is unsatisfiable as written: `.chezmoiremove`'s prune entry must name exactly that path. The CI gate implements the exclusion (`.chezmoiremove` and `docs/`) with a comment explaining why, and now also asserts positively that the prune entry still exists so the exclusion cannot become a blind spot. The plan body was not edited during execution.
- **Fix-hint path literals can drift from `$reg`.** *(maintainability, P2/75 — routed to residual on reviewer disagreement)* Four operator-facing "Fix: …" strings in the two consumers re-type `~/.config/garden/garden.yaml` instead of interpolating `$reg`. The simplification pass's quality reviewer independently ruled the substitution behavior-changing, because `$reg` prints the expanded `$HOME` path rather than the portable `~` shorthand an operator reads. Both readings are defensible; recorded rather than silently resolved.
- **Root value is encoded twice with no cross-check.** `garden.root` inside the encrypted manifest and `src="$HOME/src"` in `src-audit` now assert the same fact independently; before the relocation they agreed by construction. A `src-audit` header comment declares the invariant, but nothing verifies it. Deliberately deferred by the plan (System-Wide Impact, Boundary A).
- **Six verified garden behaviors rest on an unpinned binary.** The garden CLI floats to the newest release through the generated release lock. Most drift fails loudly, but a change to `${...}` pre-expansion timing would silently empty the `aoe_group` override, and the CI harnesses use stub binaries so they cannot observe real-binary drift. Deferred by the plan (Risk-2); the real-binary canary is listed under Deferred to Follow-Up Work.
- **Manifest content is outside CI entirely.** CI has no GPG private key, so `garden.root`, the new tree declaration, and the `aoe_group` formula (R2, R6-R10) are proven only by the local round-trip and stanza harnesses, never automatically.
- **`~/src` is absent for longer on an aborted apply.** Accepted consequence of the relocation (Risk-4). `src-audit` stays quiet in that window; interactive habits such as `cd ~/src` intermittently fail until a successful re-apply.

## Testing gaps

- No test exercises `src-audit` with `~/src` absent *and* a deliberately broken root-external tree present — the case the decision gate above describes.
- No check asserts the four fix-hint path literals stay equal to their `reg=` assignments.
- The reconcile completeness check's failure path is now covered in CI for a broken tree and an absent registry, but not for every scenario the plan's Verification Contract lists.

## FYI observations from the plan review

- The `SIGKILL` gap in the scratch-cleanup trap is acknowledged in the plan with "verify manually" and no concrete detection procedure.
- The plan's stated success criterion — a reduction in rule count — is not operationalized as a checkable outcome, and the end state still carries an exception for the checkout, now declared rather than unmanaged.
- Whether the new `.ci` script and the CI/local gate split should exist at all is recorded as an open question in the plan's own `## Deferred / Open Questions` section: both were plan-time additions, not requirements carried from the brainstorm.
