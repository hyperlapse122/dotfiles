# Orca dispatch defects — upstream report drafts

Source issue: [#438](https://github.com/hyperlapse122/dotfiles/issues/438)

Source branch: `bugfix/bound-and-reap-orca-review-workers`

Affected product: Orca IDE 1.4.198 (`/opt/Orca`, `orca-ide` RPM)

## Why these are recorded rather than filed

Both defects are in Orca, not in this repository. The shared instruction core requires the agent to
ask the user before filing an issue in a repository that is not theirs, and forbids an unattended
run from asking. The run that found them was unattended, so it uses the committed-record fallback:
the reports are drafted here for the operator to file unchanged.

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

**Local mitigation:** this repository now declares an `orca-wrapper` command-manifest unit that
deploys `~/.local/bin/orca`, ahead of `/usr/bin` in PATH, forwarding to the Orca IDE CLI. The GNOME
screen reader stays reachable at `/usr/bin/orca`, and the wrapper delegates to it on a host with no
Orca IDE installed. The trade-off — bare `orca` no longer starts the screen reader on a managed
Linux host with Orca IDE — is recorded as KTD3 and A1 in
`docs/plans/2026-09-08-2137-fix-orca-dispatch-review-contract-plan.md`.

**Proposed report**

Title: `Queued-message pointer and worker preamble hardcode bare \`orca\``

Body: The orchestration message pointer and the injected worker preamble both emit the literal
`orca` command name instead of routing through the bundle's existing `compatibilityCliCommand`
mechanism. On Linux hosts with GNOME Orca installed, `/usr/bin/orca` is the screen reader, so a
dispatched worker that follows the pointer starts speech on the user's machine. Please route both
strings through `compatibilityCliCommand` so they name the executable the session actually runs.
