# Orca dispatch defects — upstream report drafts

Source issue: [#438](https://github.com/hyperlapse122/dotfiles/issues/438)

Source branch: `bugfix/bound-and-reap-orca-review-workers`

Affected product: Orca IDE 1.4.198 (`/opt/Orca`, `orca-ide` RPM)

## Why these are recorded rather than filed

The shared instruction core requires the agent to ask the user before filing an issue in a repository that is
not theirs, and forbids an unattended run from asking. In session-settled brainstorming, the operator directed
to track/watch upstream issues locally without creating comments or issues on `stablyai/orca`.

- Defect 3 (`identity_unproven` release receipts) was reported upstream by the community and is tracked at
  [stablyai/orca#19166](https://github.com/stablyai/orca/issues/19166).
- Defects 1 and 2 remain documented here as local tracking and historical reference.
- Acceptance item 3 of [#438](https://github.com/hyperlapse122/dotfiles/issues/438) (residency verification
  command) is resolved by treating the version-matched guide's query commands as authoritative, keeping the
  instruction core command-agnostic.


## Defect 1 — `task-create --spec` cannot carry a review-sized prompt

**Observed:**

```
run: run_cc6f47cb527d
(eval):4: 인수 명단이 너무 김: orca-ide
```

That is `E2BIG` from `orca-ide orchestration task-create --spec "$(cat "$SP/adversarial.prompt.txt")"`.
The prompt files were 146–153 KB; Linux `MAX_ARG_STRLEN` is 131072. The CLI accepts the spec only as
an argv string — `out/cli/specs/orchestration.js:128` declares `--spec <text>`, and there is no
`--spec-file`, `@file`, or stdin path.

**Local mitigation:** the Orca dispatch contract in `.chezmoitemplates/agents-instructions.tmpl`
requires every dispatch spec to name a path to a brief file and forbids inlining the brief's
content, so a CE-sized prompt never reaches argv.

**Proposed report**

Title: `orchestration task-create --spec cannot carry a large prompt`

Body: `task-create` takes its spec only as an argv string, so any prompt above the kernel's
`MAX_ARG_STRLEN` (131072 on Linux) fails with `E2BIG` before the task is created. Review and
peer-review briefs routinely exceed that. Please add a file or stdin path for the spec — for
example `--spec-file <path>`, or `--spec -` reading stdin — so a coordinator does not have to
invent a file-reference convention of its own.

## Defect 2 — Orca types bare `orca` into agent PTYs

**Observed:** the queued-message pointer is generated with the command name hardcoded:

```js
function Kvn(e,t){return`\nYou have ${e} orchestration ${e===1?`message`:`messages`}. Run \`orca orchestration check${...}\`.\n`}
```

The injected worker preamble hardcodes it the same way
(`orca orchestration send --from term_… --dispatch-capability dcap_…`). The same bundle already has
a `compatibilityCliCommand` mechanism (`["orca","orca-ide","orca-dev"]`) that other hints use, but
this generator does not.

On a host where GNOME Orca is installed, `/usr/bin/orca` is the screen reader. A worker session ran
`orca orchestration send …`, got `(orca:861993): dbind-WARNING **: AT-SPI: Unable to open bus
connection`, and `~/.local/share/orca/orca-customizations.py` was created one second later — the
screen reader had started. The worker recovered with `pkill -f 'orca orchestration'`. Orca ships a
shim at `~/.config/orca/linux-orca-cli-shim/orca`, but that directory sits after `/usr/bin` in
PATH, so the shim never wins.

**Local mitigation:** this repository declares an `orca-wrapper` command-manifest unit that deploys
`~/.local/bin/orca`, ahead of `/usr/bin` in PATH. The wrapper routes by argv shape: no argument or a
leading `-` runs the GNOME screen reader at `/usr/bin/orca`, and a bare-word first argument runs the
Orca IDE CLI. GNOME Orca accepts no positional argument and every Orca IDE CLI entry point is a bare
subcommand word, so the two populations do not overlap. An Orca-IDE-shaped invocation on a host with
no Orca IDE CLI is an error rather than a fall through to speech, because that fall through is the
incident above. The original unconditional forward also captured the desktop accessibility autostart
(`Exec=orca`); that regression is [#440](https://github.com/hyperlapse122/dotfiles/issues/440), and
the argv-shape routing is its fix.

**Proposed report**

Title: `Queued-message pointer and worker preamble hardcode bare \`orca\``

Body: The orchestration message pointer and the injected worker preamble both emit the literal
`orca` command name instead of routing through the bundle's existing `compatibilityCliCommand`
mechanism. On Linux hosts with GNOME Orca installed, `/usr/bin/orca` is the screen reader, so a
dispatched worker that follows the pointer starts speech on the user's machine. Please route both
strings through `compatibilityCliCommand` so they name the executable the session actually runs.

## Defect 3 — a `retained` release receipt does not say whether anything is still resident

**Observed:** across the three orchestration runs that produced #439 (14 dispatches, all started
with `worker-start --worktree current`), `orca-ide orchestration worker-release` returned

```json
{"dispatchId":"ctx_1bff2e1ffdea","state":"retained","reason":"identity_unproven","processAction":"none","archive":null}
```

for 5 of 14 dispatches. The other 9 returned `rel=released`. `worker-stop` on the one never-done
peer returned `dispatch_inactive`.

It reproduced during the review run for this change. A supervised `--worktree current` dispatch
released as `{"state":"retained","processAction":"none"}` immediately after a succeeded
`worker_done`. `worker-show` on that same dispatch answered `status: completed`, `stage: settled`,
with `capability_revoked_at` set — while still listing the created agent terminal under
`residual_resources`. A second `worker-release` on it returned `retained` with
`reason: user_takeover`.

So the dispatch record can report a settled, capability-revoked dispatch while a terminal it created
is still listed as residual, and a coordinator cannot tell a clean no-op release from a leak by the
receipt alone. Host process counts did not grow across either run, so nothing observably leaked.

**Local mitigation:** the residency clause in `.chezmoitemplates/agents-instructions.tmpl` no longer
treats a `retained` receipt as sufficient. A retained receipt forces the run to read the receipt's
retention reason and query the dispatch once; a still-active answer forces a stop and one requery; a
retention Orca could not bind to a process is recorded as an unproven release whatever the query
says. That is [#442](https://github.com/hyperlapse122/dotfiles/issues/442).

**Proposed report**

Title: `worker-release receipts cannot distinguish a no-op release from an unproven one`

Body: `worker-release` returns `state: retained` with `processAction: none` for several distinct
situations — a deliberate user takeover, a reused or pre-existing terminal, and a dispatch whose
identity the runtime could not prove — and only some receipts carry a `reason`. A coordinator that
must account for every worker before it ends cannot tell those apart, so it either blocks on a
release that reclaimed nothing legitimately or accepts one that may have left a process behind. Two
requests. First, always populate `reason` on a `retained` receipt, and keep `identity_unproven`
distinct from the reasons that mean "there was nothing to reclaim". Second, for a dispatch started
with `--worktree current`, bind the release to the worktree identity already recorded in the
dispatch's own `start_options`, so `identity_unproven` does not fire for a dispatch the runtime
started itself.

**Upstream tracking:** tracked upstream in [stablyai/orca#19166](https://github.com/stablyai/orca/issues/19166) (`[Bug]: worker-release can never reclaim a settled worker whose PTY vanished (retained/identity_unproven on every retry)`).

## Resolution of issue #438 acceptance criteria

All acceptance criteria defined in [#438](https://github.com/hyperlapse122/dotfiles/issues/438) are satisfied:

1. **Review contract in instruction core:** PR #439 added the contract, PR #477 prohibited shell wait loops, commit `133630a` tightened the residency clause, and PR #497 moved coordinator dispatch rules to `.chezmoitemplates/orchestration-coordinator.tmpl`.
2. **Worker release after every `worker_done`:** Required and enforced in `.chezmoitemplates/orchestration-coordinator.tmpl`.
3. **Residency verification command:** Resolved by requiring "one Orca-side query of that dispatch's state" in coordinator instructions while treating the version-matched guide (`orca-ide skills get orchestration`) as authoritative for command spellings (`worker-show --dispatch <id>`, `worker-list --run <run_id> --terminal-state reclaimable`), keeping the core command-agnostic.
4. **Bare `orca` safety:** PR #439 added `~/.local/bin/orca` wrapper, and [#440](https://github.com/hyperlapse122/dotfiles/issues/440) added argv routing so desktop accessibility autostart remains unaffected while bare subcommands route to `orca-ide`.
5. **Rendered targets in sync:** Verified across all harnesses (`~/.claude/CLAUDE.md`, `~/.gemini/AGENTS.md`, `~/.codex/AGENTS.md`) by `.ci/test-agent-instructions.sh`.
6. **Upstream defect reporting:** Defect 3 tracked at [stablyai/orca#19166](https://github.com/stablyai/orca/issues/19166); Defects 1 and 2 documented here as local committed tracking without external issues or comments per operator directive.

