# Native agent hook verification

On Apple silicon macOS, disposable Git worktrees and user homes used the
managed Claude Code 2.1.329, Codex 0.171.0, Pi 1.6.0, and OpenCode 2.3.2.
A loopback fixture served scripted model responses with fake credentials.
The same cases ran through a disposable T3 Code 0.1.9 server using its
native provider adapters.

| Harness | CLI and T3 behavior |
| --- | --- |
| Claude Code | `PreToolUse` rejected a bypass commit and a frozen test write. `PostToolUse` returned the failed check and `Stop` prompted one continuation. The harmless removal of a fixture directory completed in bypass mode with the usual dangerous-rm waiver and no permission prompt. |
| Codex | The trusted `Bash` and `apply_patch` hooks saw the underlying operations inside Code Mode. The commit and a multi-file patch renaming a source file into `tests/` were blocked. A harmless multi-file patch ran the post-edit check and `Stop` prompted one continuation. |
| Pi | `tool_call` blocked the commit and test write. `tool_result` appended the check failure. `agent_before_settle` appended one corrective message. T3 used Pi's RPC transport and the provider/model form of the model ID. |
| OpenCode | `execute.before` rejected the shell command and multi-file patch. `execute.after` appended the check failure. `experimental.idle` added one synthetic follow-up to the same execution. |

Each authorized failing turn ran the task twice, after the edit and at
the first stop. The scripted correction left the diagnostic in place.
The turn then finished without scheduling another retry. Requests to the
local fixture showed the four feedback messages reaching the model in T3.
All four CLIs also settled on a clean worktree without calling the task.
The desktop presentation was outside this fixture.

Codex's headless app-server skipped unreviewed hooks. Its trust keys
include the source path, event, group index, and handler index. The T3
fixture first used different spellings of the Codex home for review and
execution. Once both used the canonical path, the same trusted hooks ran
inside the T3 turn. A changed executable store path marked the managed
hooks as modified. An unrelated trusted user hook placed after the
managed group kept its key and hash through reapplication and removal,
and ran on a subsequent turn. Codex's managed requirements can declare
pretrusted administrator policy. This user-scoped rollout uses Codex's
normal approval flow.

The repository check exercises the rendered commands and settings merger.
It covers clean and missing-task exits, the three common bypass forms,
both sides of patch renames, reactivation, the diagnostic line cap, and
the exhausted stop budget. It also checks that an unapproved checkout
with a marker and a failing task cannot start the task under a bypass
permission mode. A native Codex turn in a workspace-write sandbox
also edited the fixture without running its unapproved project task.
The production and bootstrap Home Manager hook declarations evaluated for
both hosts. Linux builds and native Linux evidence are deferred to CI. The
fixtures used temporary homes and did not activate either host.

## Upstream references

- [Codex hook discovery and trust, 0.171.0](https://github.com/openai/codex/blob/rust-v0.171.0/codex-rs/hooks/src/engine/discovery.rs)
- [Pi extension lifecycle at the managed source revision](https://github.com/earendil-works/pi/blob/faac585884ae2c013a6b1400f3e9e77f10b34bac/packages/coding-agent/docs/extensions.md)
- [OpenCode plugin interface, 2.3.2](https://github.com/anomalyco/opencode/blob/v2.3.2/packages/plugin/src/README.md)
