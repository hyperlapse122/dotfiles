# Residual Review Findings — refactor/remove-unmanaged-repo-guard

Source run: `lfg` pipeline for `docs/plans/2026-08-10-001-refactor-remove-unmanaged-repo-guard-plan.md`.
Change: deletes the `unmanaged-repo-guard` omp plugin (source, catalog entry, data,
reconciler override machinery, six CI artifacts) and replaces the mechanical
repository-management gate in `.chezmoitemplates/agents-instructions.tmpl` with a
plain-language ask-first rule.

Review coverage: `ce-doc-review mode:non-interactive` over the plan (six personas),
then `ce-code-review mode:agent` over the branch diff (seven personas —
correctness, project-standards, testing, maintainability, agent-native, security,
adversarial). Every persona ran as a separately dispatched context.

**Independence caveat.** No sanctioned cross-model peer route is configured on this
host — the repository's model policy disables the aggregator providers that would
serve one (`agents.omp.settings.disabledProviders`) — so the in-process
`adversarial-reviewer` ran as the documented fallback. `independence_verified` is
false. Agreement between personas here is across separate in-process contexts
only, never across model providers. Four findings were reached independently by
three separate contexts each; that is corroboration within one model family.

## Fixed in this change

Four instruction-core regressions the surgery introduced, all applied in
`24579c9` and recorded in the plan's `Review amendments` section:

- **P1** — `.chezmoitemplates/agents-instructions.tmpl:17`. Dropping the gate from
  the autopilot survivor list left an **attended** `lfg` run with no rule against
  filing into a stranger's tracker: the paragraph disclaims "general
  ask-before-ambiguous/irreversible-action guidance", the replacement rule is
  worded as exactly that, and the surviving tie-break sentence is scoped to
  unattended runs. Fixed by naming the ask-first rule in the survivor list.
- **P1** — `:17`. The reworded unattended sentence restored only *filing*; the base
  covered "file into or comment on". Line 50 keeps both the upstream-parent target
  rule and the key-event commenting rule, so an unattended run in a fork would
  have commented into upstream. Fixed by widening to "neither files nor comments".
- **P1/P2** — `:50`. R9 deliberately deleted the probe-result fail-closed rule, but
  ownership *judgment* has its own undecidable case and nothing selected a branch
  for it. Fixed with a judgment-shaped default: "when that context does not settle
  it, treat the repository as not the user's."
- **P2** — `:52`. Widened the exception to comment-only dispositions so the two
  paragraphs cannot disagree.

Two verification gaps, both of which the plan's own gates had missed:

- `.ci/test-agent-instructions.sh` (new, wired into `ci.yml`) pins the surviving
  rules and bans the retired probe strings by needle against the rendered target.
  Verified with a negative control.
- `.github/workflows/render-dotfiles.yml` seeds prune canaries before its isolated
  apply and asserts the guard tree is gone while the haptic sibling survives.

Record corrections: the supersession header on
`docs/plans/feedback-sweep-plan-2026-08-07.md` over-claimed (its U6 created
`.ci/lib/render-gate-helpers.sh`, which survives; U11 sits under Phase 5);
`docs/residual-review-findings/chore-resolve-feedback-sweep-open-items.md` needed
the same superseded header R19 gave its sibling;
`docs/plans/feedback-sweep-plan.md` decision 3 and R1 prescribed the precedence
back-reference R9 deletes; `.chezmoidata/agents.yaml:159` still said "DEFAULT"
after the only override path was removed; and the decommission checklist pointed
at a line number that landed on the reversed decision, over-claimed the surviving
plugin set on container hosts, and routed third-party repository names into a note
committed to a public repository.

## Filed as issues

- **P1** — `.chezmoiremove` prune entries have no CI assertion.
  `.chezmoiremove:133`. A non-matching entry makes `chezmoi apply` exit 0 with no
  diagnostic (verified directly), and the only job that evaluates the file applies
  into a fresh fake HOME and discards the exit code. This change closes the gap for
  its own entry; the other eight remain unasserted.
  → [#192](https://github.com/hyperlapse122/dotfiles/issues/192)
- **P3** — `.chezmoitemplates/fingerprint.tmpl:22-27` accepts a zero-match glob in
  silence, so `$fingerprintInputs` fails quietly in both directions — a stale path
  contributes nothing, and an omitted real dependency stops `run_onchange_` from
  re-triggering. Demonstrated: re-adding the two deleted guard globs produced a
  byte-identical render.
  → [#193](https://github.com/hyperlapse122/dotfiles/issues/193)
- **P2** — `.chezmoiignore:116`'s container narrowing lost its beneficiary with the
  guard. No container row uses the `h82-dotfiles` `localDir` marketplace, so the
  catalog deployed there is inert. Deferred by KTD6 because re-widening breaks
  `.ci/test-mxm4-haptic-gates.sh:73` inside a removal change.
  → [#194](https://github.com/hyperlapse122/dotfiles/issues/194)

## Settled-decision conflict — needs your ruling

**The Product Contract's KD3 was amended during planning, and that amendment
shipped.** As authored, KD3 read "Unattended runs file without a gate" and had
R12/R13 delete the `lfg` carve-out and the review-findings exception outright — so
an unattended run would file into any repository.

Issue [#184](https://github.com/hyperlapse122/dotfiles/issues/184), the origin this
plan cites, says the opposite in its own **Must survive verbatim in meaning** list:

> The unattended `lfg` prohibition on filing into a repository the user does not
> manage. An autopilot run has no user to direct it and gains nothing from this
> change.

The follow-up comment authorizing this plan reads, in full, "remove
`unmanaged-repo-guard` as well" — it is about the plugin. KD3's stated basis, that
the user chose filing over declining, appears nowhere in the issue thread.

Planning resolved this by **rewording rather than deleting** (KTD9): the probe is
gone, the destination rule survives as ownership judgment. Two independent code
reviewers separately flagged the unamended version as creating an irreversible
public-write path with no human in the loop.

**If you intended KD3 as authored, the reversal is one edit**: in
`.chezmoitemplates/agents-instructions.tmpl`, delete line 17's unattended sentence
and line 52's second exception instead of the reworded forms now present, and drop
the corresponding needles from `.ci/test-agent-instructions.sh`.

## Advisory — recorded, not actioned

- The phase-70 reconciler installs and enables but never uninstalls, so
  `unmanaged-repo-guard@h82-dotfiles` stays loaded from `~/.omp/plugins` on every
  provisioned host until an operator runs
  `docs/decommission/unmanaged-repo-guard.md`. Documented in `.chezmoiremove` and
  in the checklist itself; nothing in the repo can close it, and root `AGENTS.md`
  forbids the teardown script that would.
- AE1 and AE2 assert runtime agent behavior. The plan attributes the absence of
  automated coverage to U3 deleting the stub-model harness; a reviewer noted that
  attribution is imprecise — AE2 asserts model judgment, which a scripted stub
  could not have decided either. The gap is structural. The new
  `.ci/test-agent-instructions.sh` covers the textual half; the behavioral half
  stays with the checklist's step 5 spot-check.
- `omp plugin uninstall --dry-run` is not honored — it performs the uninstall.
  Observed on this host on 2026-08-10 (the probe uninstalled the plugin; state was
  restored immediately). The checklist warns about it. Upstream `omp` behavior, not
  this repository's to fix.
- `omp plugin uninstall`'s resolution from `installed_plugins.json` rather than the
  catalog is what makes the checklist's ordering claim true. That was observed on
  one host at one pinned version and is not reproducible from the repository; an
  `omp` upgrade could invalidate it silently.

## Run context

Branch `refactor/remove-unmanaged-repo-guard`, base `2dcf776`. Plan:
`docs/plans/2026-08-10-001-refactor-remove-unmanaged-repo-guard-plan.md`.
