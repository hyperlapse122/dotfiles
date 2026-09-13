# Coordinator wait preflight

Plan: [Coordinator background waits](../plans/2026-09-13-1424-refactor-coordinator-background-waits-plan.md).

## Current gate

U0 is incomplete. Do not start U1 or claim cross-harness behavior from these checks.
No candidate instructions have been deployed. The coordinator plan's U1 and U2 have not run. The separate pin plan's U1 is committed locally, but its U2 runtime gate failed. Review, PR creation, and shipping have not run.

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
