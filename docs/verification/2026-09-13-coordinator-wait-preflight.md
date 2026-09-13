# Coordinator wait preflight

Plan: [Coordinator background waits](../plans/2026-09-13-1424-refactor-coordinator-background-waits-plan.md).

## Current gate

U0 is incomplete. Do not start U1 or claim cross-harness behavior from these checks.
No candidate instructions have been deployed. The coordinator plan's U1 and U2 have not run. The separate pin plan's U1 is committed locally. Its candidate hook and supervised lifecycle checks now pass after the compatibility repair below. Review, PR creation, and shipping have not run.

The user authorized the compatibility repair. The missing Antigravity guard decision
is now fixed in source, with passing regression tests and a successful isolated
supervised lifecycle. Native permission checks remain in force.

## Confirmed observations

- Orca reports version 1.4.200. The Antigravity CLI reports 1.2.2.
- Orca's agent ID is `antigravity`; its executable is `agy`. A start with `--agent agy` does not test whether Antigravity is configured.
- A direct Bubblewrap agent launch failed supervised attachment with `agent_unconfigured` and `is not running a recognized agent`.
- Starting an interactive shell in Bubblewrap, then sending `agy` through Orca terminal input, allowed `worker-start --terminal` to accept a probe. The probe returned `worker_done`.
- The isolated process's `~/.gemini/AGENTS.md` hash matched the candidate. The host file retained SHA-256 `387bef841ec34510d99000021f29b0fa5ff950343df8ad3916fd04a259a142df`.
- That probe reported no appended startup marker and no normative Orca injection. Its report is model self-report, not a capture of the full model input.
- The user confirmed the probe paused for command execution approval and that they approved it. This delay is not evidence about background execution or automatic wake.
- Release of the pre-existing probe terminal returned `external_terminal` with no process action. The run closed its own settled terminal and acknowledged the delivery. No dispatch remained reclaimable.
- A fresh, non-isolated startup traced with `strace` opened the installed plugin manifest and hooks file. After its first prompt, it also opened `~/.gemini/AGENTS.md`. Its tool-free response confirmed separate `user_global` instructions but reported no Orca normative injection.
- The installed plugin passed `agy plugin validate`; its `config.json` entry was enabled. File validity and discovery do not prove hook execution or model injection.

## Investigation

The claim that Antigravity does not read `~/.gemini/AGENTS.md` is contradicted by the fresh startup trace. Check marker placement and model-context delivery separately.

The isolated probe put a marker at the beginning of the unchanged user instruction body. Its tool-free response returned the exact marker `orca-startup-top-verified`. This confirms candidate loading through the user-global path. It does not establish why the earlier appended marker was missed.

The same probe traced the instruction-file open and the installed hook executable. It opened the instruction file and plugin hooks declaration, but recorded no execution of the installed hook. The model again reported only the pointer, not the normative injection.

A location comparison bound that same hook declaration at the global hooks path inside the child namespace. This was a tool-free diagnostic, not a coordinator evaluation: the child temporarily lacked Orca's separate status-hook declaration. The trace recorded reads of the global hooks file but no execution of the installed hook. The model returned the startup marker and again reported no normative injection. Moving the declaration is therefore not a verified fix. Both host hashes remained unchanged, including the global hooks hash `fe0e18dcb6bcf85b0a196aad85dccce8bdfc105549dac2726eeb8dff7f19a2b7`.

All diagnostic terminals from this pass were closed. No worker dispatches were created in this pass. The unresolved boundary is hook execution in agy 1.2.2, not command approval or user instruction file replacement. Investigate the harness's hook activation and execution conditions before another coordinator evaluation. An `openat` trace proves file access only; absence of the selected `execve` proves no matching execution in the traced process tree, not the internal reason or behavior of an untraced service.

The tests use Orca-owned terminals and native authentication. They do not copy credentials, change permission settings, overwrite live instructions, or relax dispatch rules.

## Independent review and final activation check

A read-only Claude review found that the declaration and response envelope match the installed binary's documented shapes. It also confirmed that existing tests invoke the hook binary directly and do not prove that agy calls it. This is evidence against a declaration typo, not proof that the entire integration works. The review returned `worker_done`; its terminal was released before acknowledgement.

The review proposed checking workspace trust, inherited Orca identity, and Orca's own global hook as a control. The checks found:

- The exact worktree path was present in agy's `trustedWorkspaces`.
- The diagnostic agy process inherited the runtime-issued `ORCA_TERMINAL_HANDLE`.
- A fresh tool-free model request returned `TRACE_MODEL_DONE`.
- An unfiltered process-tree trace recorded executable calls as raw addresses, without argument or environment values, and recorded file opens. It found no open of Orca's `antigravity-hook.sh` during the completed request. Earlier path-filtered traces found no execution of the dotfiles hook.
- A separate launch using agy's supported `--log-file` option again reported no injected contract. The diagnostic log yielded no hook-related error explanation.

The binary contains an internal `CustomizationConfig.EnableJsonHooks` field. This is not evidence of a supported user setting or of its runtime value. Do not add a guessed configuration key to force it. Symbol-based disassembly failed with `no symbol section`.

U0 remains blocked at Antigravity hook activation. A working hook-enabled launch or an upstream-supported repair is needed before coordinator evaluation. The tests do not establish the internal cause, so no production fix, permission change, hook relocation, or weaker verification contract was applied. All diagnostic terminals were closed; no dispatch remained reclaimable.

## Upstream regression report and version control

The upstream tracker has an exact symptom match in [issue #1008](https://github.com/google-antigravity/antigravity-cli/issues/1008): versions 1.2.1 and 1.2.2 load named hooks but never execute them; version 1.1.28 works with identical configuration on the reporter's macOS host. The local 1.2.2 diagnostic log also records `loaded 1 named hooks from 1 hooks.json file(s)`. Discovery therefore succeeded without observed execution. No issue or comment was posted upstream.

The official 1.1.28 Linux x64 release archive was downloaded into a temporary directory. Its SHA-256 matched the release asset digest `074ff4f732a750ad727aeed5fc82ed34b1fb72fda2a6ceba6c8e652ffd0a94b0`. The control launch substitutes that executable only inside Bubblewrap. A temporary overlay over `~/.gemini` isolates native runtime writes while preserving native authentication reads and the existing configuration. It does not change the installed executable or deploy instructions.

The 1.1.28 launch succeeded. The trace recorded Orca's `antigravity-hook.sh` opening and the dotfiles `orchestration-hook hook --harness agy` executable running. In a tool-free model request, Antigravity reported a separate normative block delimited by `orchestration-everyone:begin` and `orchestration-everyone:end`, then returned `HOOK_VERSION_CHECK_DONE`. This supplies both process evidence and model self-report, not a raw capture of the complete model input.

Only Linux x64 was tested locally. Earlier 1.2.2 probes did not all use this same temporary overlay, so this is a verified working 1.1.28 configuration, not a fully matched single-variable A/B experiment. The diagnostic terminal was closed. The installed version remains 1.2.2, and host instruction and global hook hashes remained unchanged.

The authenticated user was subscribed to issue #1008 on 2026-09-13. GitHub returned `viewerSubscription: SUBSCRIBED`. This is an issue subscription, not a repository-wide watch.

The hook-activation obstacle has a tested workaround, but the original U0 gate remains incomplete because coordinator background-wait behavior has not been verified. Version pinning and its removal gate are scoped separately in [Antigravity hook version pin](../plans/2026-09-13-1533-fix-antigravity-hook-version-pin-plan.md).

## Native updater control

The [official troubleshooting guide](https://antigravity.google/docs/cli/troubleshooting/) documents `AGY_CLI_DISABLE_AUTO_UPDATE=true`. A fresh isolated 1.1.28 launch with that variable recorded `Auto-update disabled via environment variable AGY_CLI_DISABLE_AUTO_UPDATE` in its native log. The same log recorded one loaded named hook. This proves the updater accepted the control, not hook execution or coordinator behavior.

The variable was set only in the diagnostic child process. No live shell or desktop environment configuration changed. Source ownership and regression tests must cover both supported operating systems before the pin is complete.

The diagnostic terminal was closed after reading the updater log. Both host hashes above still matched, and the managed executable still resolved to the installed `1.2.2-74342cf2a78b` command-store entry.

## Matched version comparison

Both versions ran in fresh Orca-owned terminals with the same Bubblewrap overlay over `~/.gemini`, the same native authentication reads, and `AGY_CLI_DISABLE_AUTO_UPDATE=true`. The executable bind selected 1.1.28 for the candidate and the installed 1.2.2 for the control. Both logs confirmed that the native updater was disabled.

The first marker attempt bound the plugin source under `~/.local/share`, but Antigravity read its installed copy under `~/.gemini/config/plugins/dotfiles-agy`. The model returned `ABSENT`, and the trace showed the original hook instead of the marker wrapper. That attempt does not count as marker proof. Its terminal was closed.

The corrected comparison bound the same test declaration at the installed plugin path in each child namespace. The wrapper called the unchanged dotfiles hook and appended an ephemeral marker only when the real hook emitted an injection array. The launch guard and Orca's global hooks remained unchanged. The tool-free prompt asked for the marker but did not contain its value.

| Observation | Candidate 1.1.28 | Control 1.2.2 |
|---|---|---|
| Orca status-hook file opened | Yes | No selected trace match |
| Marker wrapper and real dotfiles hook executed | Yes | No selected trace match |
| Exact injected marker returned | `a8cb054d-132f-410a-8867-5fd4d643efad` | `ABSENT` |
| Normative everyone block reported | Present | Not present |

Both responses ended with `MATCHED_CONTEXT_DONE`. The rendered terminal screen supplied response evidence; the repainting stream omitted some response lines and was not used as the verdict. The control terminal was closed. These observations prove the tested Linux x64 startup difference, not the internal regression cause or coordinator waiting behavior. The candidate next enters a separate supervised lifecycle probe.

The marker-wrapped candidate accepted a supervised dispatch but could not complete it. Its attempt to check the coordinator inbox was denied with `tool call denied by pre-tool hook`. It ended its turn without `worker_done` and reported that the denial carried the injected normative block and marker. This is not approval waiting and does not establish that the unchanged production hook permits tool execution. A separate check with the original declaration is required before pin rollout.

Recovery used the terminal's final failure report as positive stop evidence. `worker-stop` returned `stop_unknown` because the terminal was externally owned. `worker-abandon` fenced the dispatch, and release retained the external terminal without a process action. After confirming the original terminal handle and incarnation, the diagnostic owner closed that terminal. The reclaimable-worker query was empty. No successful lifecycle result is claimed for this attempt.

A fresh 1.1.28 retry used the original installed hook declaration with no marker wrapper or plugin-file bind. It reproduced `Encountered error in tool execution: tool call denied by pre-tool hook:` on the coordinator inbox command and ended its turn without `worker_done`. The worker reported the normative orchestration text in the denial. That report does not prove the internal parser cause. It does rule out the marker wrapper as a necessary trigger in these two observed attempts.

The retry was abandoned after its explicit final failure report. Release performed no process action on the external terminal. The diagnostic owner verified its handle and incarnation and closed it. Both attempts failed the supervised lifecycle criterion; neither is approval waiting. The pin rollout and original coordinator evaluation remain blocked. The next decision is whether to expand implementation to diagnose and repair the Antigravity pre-tool hook compatibility, with permission policy unchanged, then repeat both gates.

## Version-pin implementation checks

Commit `edeb1a0` implements pin-plan U1. The selected generator changed only `agy` in the lock; a full scratch refresh also advanced three unrelated tools and was not installed. All four official archive URL and SHA-256 renders passed. Parent-run package verification passed 507 tests across five packages, `vp check`, and recursive type checks after `vp install --frozen-lockfile`. The CI wiring regression passed.

For U2, the updater declaration test first failed because the Linux environment setting was absent. After adding source declarations for Linux desktop processes and common zsh startup, the test passed for both unset and inherited-false shell values and confirmed export to child processes. ShellCheck and the CI wiring regression passed. These are source checks, not live deployment or macOS runtime proof.

## Pre-tool decision compatibility

The user authorized resolving the remaining blocker. A fresh isolated 1.1.28
terminal traced only handler arguments and response keys. PreInvocation called
`hook --harness agy` and received `injectSteps`. PreToolUse called
`guard --harness agy` and received `{}`. This rules out the proposed handler mix-up
for this reproduction. A denial message containing injected instructions was not
reliable evidence of the handler that ran.

The [official hook contract](https://antigravity.google/docs/hooks) requires a
PreToolUse `decision`. `ask` respects existing permission grants; `allow` overrides
native approval. Orca's installed Antigravity status hook also returns `ask` for
PreToolUse. The dotfiles guard incorrectly assumed `{}` was neutral on every
harness.

The first `printf ORCA_BOUNDARY_OK` attempt received a hard pre-tool denial. Changing
only the isolated adapter's `{}` response to `{"decision":"ask"}` made the same
command reach Antigravity's native approval screen. The run did not approve the
command or change permission settings. This demonstrates the decision-parser
boundary, not successful execution or a completed worker lifecycle.

The source fix returns `ask` on Antigravity's non-denial paths, including malformed
input, outside-Orca operation, and internal errors. Claude and Codex retain `{}`;
forbidden launches retain `deny`. Three regression tests failed against the old
implementation, then all 159 hook tests passed. The compiled-binary gate,
formatting, lint, and type checks passed. The initial root-directory test command
failed to load template imports; the package-local Vite configuration was required.

The previous test suite checked the binary response against an incorrect expected
shape. It did not test Antigravity's interpretation of that shape. The native
counterfactual supplies that missing evidence. A fresh compiled source binary is
ready in the diagnostic directory, with the response-rewriting adapter removed.
No live files were deployed by this run.

The operator approved `printf ORCA_BOUNDARY_OK`; it printed the expected marker
and exited 0. The subsequent lifecycle probe reached native permission checks,
but its source-binary provenance failed. The host hook changed from build
`44795880346123b9` to `7ed84a2f5e2c8283`, with modification time 16:40:08 local.
The child mount table no longer contained the trace-hook bind, and its hook path
resolved to the host binary. The trace log had no entries for the lifecycle
probe. The cause of the host replacement is not established. Neither approval
nor a worker success report can prove the candidate ran in this state.

Dispatch `ctx_661fb842864e` also copied bare `orca` from the injected preamble.
The coordinator canceled that pending command before execution, sent a durable
executable correction, and resumed the same dispatch with `orca-ide`. The inbox
command then completed after operator approval. Its `worker_done` was accepted
as `msg_c0a683dc2df0`. Release returned `external_terminal`, so the diagnostic
owner verified the terminal identity and closed it. Orca confirmed `ptyKilled:
true`; delivery `delivery_77745ce73ab9` was then acknowledged. No worker remained
reclaimable. This settles the dispatch but does not prove candidate execution.

A fresh isolated terminal instead binds a test declaration at the installed
plugin's hooks path inside the temporary Gemini overlay. Both events call the
fixed wrapper by its absolute temporary path, not through the mutable host hook
path. The wrapper executes the compiled source binary without rewriting its
response. A tool-free request produced a new `hook --harness agy` trace with
`injectSteps`; the model reported a separate normative block. The candidate
binary SHA-256 is `9c6d131ba85d05da18d7bf84ee2ce461d42812f8dc04e3920d39ad66f031d0f2`.

Dispatch `ctx_592693e0f561` completed its inbox check and sent `worker_done`
`msg_030d169844a3` after the operator approved both commands. Each command produced
a new `guard --harness agy` trace with `decision: ask`; model invocations produced
`injectSteps`. The compiled binary retained the SHA-256 above. This verifies the
source fix through Antigravity's native `run_command`, not only through direct
binary tests. The unchanged deny path remains covered by the real-binary gate;
the runtime probe never launched a forbidden peer.

Release returned `retained`, `external_terminal`, and `processAction: none`.
The follow-up query confirmed `completed` and `settled` with no residual resources.
The diagnostic owner closed the exact terminal, and Orca confirmed `ptyKilled:
true`. Delivery `delivery_a8db962a0483` was then acknowledged. No dispatch remained
reclaimable. The live plugin declaration retained its original hash.

## Managed command selection

The source command manifest was rendered with the shared isolated helper and
filtered to the `agy` unit. Its identity was `1.1.28-074ff4f732a7`. The real
command reconciler activated the verified candidate in a throwaway destination
through `activate-unit --manifest <rendered manifest> --unit agy --home <scratch>`.
Both public names, `agy` and `antigravity`, resolved to the same immutable store
file. Both printed `1.1.28`; both retained executable SHA-256
`a8793092fbe6eea0b8228fc20582ec306f7f7698d1151be526902b1556a76f3a`.
The live command links were not changed.

The existing command-manifest gate failed because it still required a null
Antigravity SHA-256 and a SHA-512 store identity. Its updated assertions check
the pinned SHA-256 identity and both aliases. A separate render-time fixture
keeps the SHA-512 fallback covered. The gate now uses the shared render helper,
an empty config, an isolated destination, and a restricted PATH with a stub
`op`. The updated gate and ShellCheck passed.

The package-root `vp test` invocation failed before executing tests because its
runner did not share the package-local Vitest suite context. The repository's
`vp run test` script uses the package-local commands and passed 509 tests across
five packages, with valid cached results for four unchanged packages. `vp check`
and `vp run typecheck` passed. No test or configuration was weakened to resolve
the invocation mismatch.

## Coordinator mechanism checks

These checks use ordinary Orca-owned coordinator terminals, not dispatched
workers asked to lead. Each coordinator creates its own Run without another
terminal's identity. Dispatch count is zero. Synthetic `question` messages test
native execution and continuation only; they do not establish the U2 worker
lifecycle criteria or verify the proposed instruction changes.

### Isolation and context

A full temporary overlay of `/home/h82` preserved instruction loading but hid
Orca's runtime bootstrap and IPC. The first coordinator attempts therefore
failed with `runtime_open_timeout`; namespace preflight also reported
`stale_bootstrap`. They created no Run. Their diagnostic terminals were closed.

The corrected Bubblewrap recipe keeps the home overlay, rebinds the native
`~/.config/orca` and `~/.orca` directories for runtime communication, then applies
another temporary overlay to the Codex account home below `~/.config/orca`.
Each harness instruction file is a read-only bind of its isolated render.
Antigravity also binds the verified 1.1.28 executable and the fixed temporary
hook declaration. Its native updater stays disabled. This preserves native
authentication without copying credentials, and keeps harness configuration
writes inside the overlay. A pre-launch `orca-ide status --json` reported the
same reachable Orca 1.4.200 runtime inside and outside the namespace.

Tool-free reports returned the exact `coordinator-u0-<harness>-F74lvU` markers
from user-scoped context for Claude, Codex, and Antigravity. All three reported
the normative everyone block. Codex and Antigravity reported repository
`AGENTS.md` in their initial context. Claude did not; it read that file before
the experiment. These are model-context reports, separate from filesystem
replacement evidence.

Codex was requested as `gpt-5.6-luna` with `max` effort and displayed that pair
in its TUI. This custom coordinator launch supplied no `launch.requested` and
`launch.effective` pair, so its model receipt remains unverified. It is not a
Luna/max review pass.

### Claude Code 2.1.270

Run `run_75a127ed83da` was created at 08:08:37 UTC. One `Bash` invocation with
`run_in_background: true` started the canonical wait and returned task handle
`bsgcxqkoj`. The coordinator ended its turn with `ARMED`. The parent sent
synthetic question `msg_0c58ec30b1ba` at 08:09:21 UTC, about 43 seconds after
the wait started. No model-driven status or filler call occurred in that gap.
The CLI emitted its own heartbeat lines; those were not extra model calls.

The terminal then displayed a background-command completion notification with
exit code 0. The model resumed without another terminal prompt and read the
completed task output. It replied at 08:09:29.57 and acknowledged
`delivery_e64470b10e2d` at 08:09:33.77. There was one background wait, one output
read after notification, one reply, and one acknowledgement. No duplicate wait,
timer, or status polling occurred. The observed wake was a native
`task-notification` for that handle, not a desktop notification. This proves
after-turn resumption for normal command completion in this active session.
It does not cover a killed or interrupted session.

The active Bash schema reports a 600,000 ms timeout maximum, distinct from the
Orca wait's 900,000 ms flag. A native command timeout must therefore be handled
as an execution result, not mistaken for an Orca delivery. This experiment did
not wait for either timeout.

### Codex CLI 0.154.0

Run `run_0224f3b16d9d` used one `exec_command` wait with a 1,000 ms initial yield
and returned session `32266`. One empty-input `write_stdin` call continued that
same session with a requested 60,000 ms blocking interval. The coordinator
reported 48.910 seconds for the continuation before the question arrived.
The parent sent `msg_c203f42874d6` at 08:10:24 UTC. The coordinator handled
`delivery_6c81b0280fde`, replied, and acknowledged it without another wait.

No worker, duplicate wait, or status poll was involved. The agent kept its turn
open until result handling finished. This demonstrates same-handle blocking
continuation, not automatic wake after a final response. The schema inspection
does not grant that latter guarantee. Yielding execution therefore has a
nonzero continuation-call cost that depends on wait length and active limits.

Both completed coordinator terminals were closed after their final reports
and identity checks. Orca returned `ptyKilled: true` for each. Their Runs remain
as durable evidence; neither has a dispatched worker to release.

### Antigravity 1.1.28 checkpoint

The fresh `Antigravity coordinator U0 IPC` terminal loaded the isolated marker
and reported native `run_command` and `manage_task` tools. It reported reactive
completion wake in its instructions, but that report is not runtime proof.
After native approvals, it created Run `run_5a8bdc789cb5` at 08:14:40 UTC.
One native background wait started at 08:14:45 and returned task handle
`b727d68e-2ced-4437-ab23-2eab8b53f328/task-12`. The model ended with `ARMED`.
The parent sent synthetic question `msg_57dc55e0b392` at 08:15:36, after about
51 seconds. No further terminal prompt was sent to the model. It resumed,
identified completed-task output, and requested its reply command. No timer or
status call appeared during the silent interval. This is observed native
completion-triggered continuation after a final response, not only the earlier
schema claim.

The operator approved the reply and acknowledgement separately. The final
report names reply `msg_6722e15f4124` at 08:17:27 UTC and acknowledged delivery
`delivery_d5c91a12a342` at 08:17:30. It identifies the resume event as a native
high-priority completed-task message carrying exit code 0 and stdout JSON.
The run used no `manage_task status` calls or timers during silence. The
diagnostic owner verified incarnation `6848c806-e7b6-4b9f-a5a0-3f966db7b050`
and closed terminal `term_c0c89593-f800-4aab-83f3-00cea02e594f`; Orca returned
`ptyKilled: true`.

U0 now establishes the isolated coordinator path and native continuation for
all three harnesses. Claude and Antigravity can end a turn with a live native
completion wake; Codex must keep its turn open through blocking continuation.
The foreground setup and acknowledgement commands also exercised immediate
results without running-command handles. Timeout and error handling under the
candidate policy remain U2 checks, not conclusions of these success traces.

## Shared policy implementation

U1 moves the coordinator execution policy to the shared wait section and keeps
native tool arguments on each harness's existing instruction line. The shared
examples no longer require an unconditional turn end. The omp adapter is
unchanged. This unit was integrated inline because it depends on the live U0
observations and operator-mediated verification; no independent write wave
exists in the U0, U1, U2 dependency chain.

The strengthened gate first failed on all eight harness/OS renders because the
shared execution clauses were missing and the examples unconditionally ended
the turn. After the source and fixture changes, the Linux and macOS render gate,
ShellCheck, and `git diff --check` passed. The gate checks the shared clauses,
native adapter isolation, whole-section fixtures, and retired turn-ending text.
Static checks do not complete U2's runtime scenarios.

## Candidate-policy evaluation: Claude and Codex

Both coordinators loaded the U1 candidate at user scope through the U0 overlay
recipe. Their markers were `coordinator-u2-claude-oCVAEB` and
`coordinator-u2-codex-oCVAEB`. Both reported the common policy and normative
injection before execution. Claude read the repository supplement before work.
The fixtures required two read-only workers, a delayed question from A, and a
delayed completion from B. Worker sleeps were test stimuli, not coordinator
polling. Each worker had a ten-minute deadline; each Run had a fifteen-minute
bound.

Claude initially requested broad access for a `/tmp` brief. The parent canceled
that prompt without granting access or using a shell bypass. The replacement
briefs live in `docs/verification/coordinator-wait-u2/`. Claude used two Claude
workers. Codex had already read its original temporary brief and used two Codex
workers. Its one `prepare-codex` attempt returned `EROFS` while writing temporary
hook state. It made no manual trust edit and did not repeat that command. Both
subsequent starts succeeded. This is a preparation limitation of the isolated
coordinator, not evidence that Codex dispatch failed.

### Claude Code 2.1.270

Run `run_78242612ec75` used these worker attempts:

| Worker | Task | Dispatch | Release completed, UTC |
| --- | --- | --- | --- |
| A | `task_481e365861d3` | `ctx_bfaf1fa318f9` | 08:34:36 |
| B | `task_e1ad7b180b6c` | `ctx_67ffcc2c0c5a` | 08:35:24 |

Three background Bash waits returned handles `bqnhbh07w`, `bmleujtuf`, and
`b4xs4a37b`. Each completed through one native notification and an output read
after that notification. There were no status polls, duplicate watchers, or
blocking continuation calls. The first quiet interval was about 90–105 seconds;
the last CLI keepalive reported 90,023 ms. Keepalives are CLI output, not model
tool calls.

The first wait delivered question `msg_9092d93e749f` in
`delivery_849cb9ce2a41`, created at 08:34:08 UTC. The coordinator replied
`U2_PROCEED` in `msg_d7f4af0ae1a4`, then acknowledged on the next wait.
The second wait delivered A's `msg_c53fd451ce95` in
`delivery_af8a32e2058e`; the third delivered B's `msg_fb73cbcde051` in
`delivery_4f85346caf56`. Both releases preceded their Delivery acknowledgements.
The final acknowledgement started no further worker wait.

After settlement, the 1,000 ms diagnostic returned `timedOut: true`, no Delivery,
and zero messages. The ordinary command returned exit code 7. Neither result
received a fabricated acknowledgement. Claude ran those two independent
diagnostics and the final reclaimable query in parallel, although the fixture
specified sequential diagnostics. This deviation did not change worker waiting
or lifecycle ordering. The parent verified both attempts succeeded and both
resources were released with captured transcripts.

### Codex CLI 0.154.0

Run `run_c070fc6adc2f` used these worker attempts:

| Worker | Task | Dispatch | Release completed, UTC |
| --- | --- | --- | --- |
| A | `task_b3004ae6097c` | `ctx_20612b4b104a` | 08:33:13 |
| B | `task_cd767b449b2e` | `ctx_8949071290ba` | 08:32:29 |

The parent inspected both `worker-show` receipts. Each recorded requested and
effective model `gpt-5.6-luna` with effort `max`. This establishes the worker
pair only; the custom coordinator launch still has no equivalent model receipt.

The coordinator reported these native waits and same-handle continuations:

| Native session | Result | Reported elapsed time | Continuation calls |
| --- | --- | --- | --- |
| `71388` | A's question | 105,027 ms | 4 |
| `25243` | B's completion | 45,018 ms | 2 |
| `54264` | A's completion | 30,010 ms | 1 |

Question `msg_67efa4d9e4e2` arrived in `delivery_d56525927d1a`. Reply
`msg_0cc853426e11` carried `U2_PROCEED`. B's completion arrived in
`delivery_a9acdb66f228`; A's completion arrived in `delivery_bb8f7ae267de`.
The visible trace showed release before acknowledgement for each completion.
It showed blocking continuation of the same native handles, with no duplicate
Orca wait or timer-driven status calls. The coordinator kept its turn open
until both workers settled and the diagnostics finished.

Diagnostic session `26160` timed out after 1,000 ms with zero messages. The
ordinary command returned exit code 7. Neither supplied a Delivery to acknowledge.
The final reclaimable query returned no workers. The parent's scoped query
confirmed both attempts succeeded, resources were released, and transcripts
were captured. These results establish bounded continuation, not automatic
Codex wake after a final response.

### Additional pin regression check

The external-checksum regression still assumed Antigravity had only SHA-512.
It failed with `agy now records a sha256; the sha512-only case must be updated`.
Commit `7dbc15a` updates the pinned-artifact assertion, preserves a separate
SHA-512-only fixture, and uses the existing isolated render helper. The full
checksum regression, `shellcheck -x`, and `git diff --check` passed. Plain
ShellCheck without `-x` did not follow the sourced helpers; its missing-source
and unset-scratch reports were invocation errors, not test passes.

Antigravity U2 remains in progress. Neither these two coordinator results nor
the pin regression completes the three-harness verification requirement.

After the final reports, the parent verified each coordinator incarnation and
closed its ordinary terminal. Orca returned `ptyKilled: true` for Claude
`term_22522ec5-b625-49e6-ac80-838f2f8a0127` and Codex
`term_6fd62148-7ee9-4463-bd33-6214413729f6`. No worker required a further
ownership decision.

### Antigravity U2 approval checkpoint

The parent created terminal `term_540a0632-f4af-442d-9d12-74430261e7bf`,
incarnation `f53675aa-aac9-497e-b596-a3fda5866d3c`, through the same isolated
1.1.28 and fixed-hook recipe. Its TUI reported Antigravity 1.1.28. A tool-free
preflight reported marker `coordinator-u2-agy-oCVAEB`, the candidate coordinator
policy, normative everyone injection, and repository supplement in loaded
context.

The accepted evaluation prompt authorized exactly two read-only Claude workers.
The coordinator read the repository-local brief and requested access to
`/home/h82/.agents/skills/orchestration/SKILL.md`. Native file approval remains
pending before Run creation or dispatch. The parent requested approval for
that file only and did not select either the one-time or permanent permission.
This is an operator approval checkpoint, not a failed native wake test or a
completed U2 result.
