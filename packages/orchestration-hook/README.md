# @h82/orchestration-hook

This package delivers the Orca instruction payload to the two JSON hook
clients. The plain-output extension client receives the same role-aware
context through `packages/omp-orca`.

The compiled binary is staged at `~/.local/libexec/orchestration-hook`. It has
no runtime package dependencies and does not need a shell, `jq`, or Bun on the
managed host.

## Commands

| Command | Purpose |
| --- | --- |
| `orchestration-hook hook --harness <id>` | Deliver role-aware context and exit 0 on every path. |
| `orchestration-hook guard --harness <id>` | Compatibility no-op for a stale cached hook declaration: answers the harness's empty allow output and exits 0 without reading stdin. |
| `orchestration-hook print-payload --body <everyone\|coordinator>` | Print an embedded payload body. |
| `orchestration-hook role` | Print the resolved role and its environment inputs. |
| `orchestration-hook --version` | Print the build identifier. |

Lead delivery is atomic. The hook emits no partial context when the local Orca
guide is unavailable. The plain-output client replaces one managed block in its
system-prompt array on each `before_agent_start` event.
