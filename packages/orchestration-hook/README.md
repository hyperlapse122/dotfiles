# @h82/orchestration-hook

Delivers this checkout's orchestration payload to an agent session at `SessionStart`.

Compiles to a single standalone binary staged at `~/.local/libexec/orchestration-hook`.
Each harness's plugin `hooks.json` invokes it by absolute path, so the session-start
path depends on no shell, no `jq`, and no `bun` on `PATH`.

## Commands

| Command | Purpose |
| --- | --- |
| `orchestration-hook hook --harness <claude\|codex>` | The `SessionStart` handler. Writes one envelope on stdout and always exits 0. |
| `orchestration-hook print-payload --body <everyone\|coordinator>` | Prints an embedded payload body. The parity gate compares it against the source body. |
| `orchestration-hook role` | Prints the resolved session role and the three environment inputs it read. |
| `orchestration-hook --version` | Prints the build identifier. |

`hook` is the only subcommand that fails open: any error, unknown flag, or
unparsable argument still yields the harness's empty envelope and exit 0, because
a `SessionStart` hook that errors delays session start. Every other subcommand uses
ordinary CLI conventions — diagnostics on stderr, non-zero exit on error.

## Payload bodies

The two bodies in `.chezmoitemplates/` are the single source. `src/payload.ts` embeds
them at build time, and chezmoi renders the same files for omp's instruction file,
which has no session-start injection point. Neither body may contain template actions:
the build embeds raw bytes and does not render.

## Roles

`none` — not Orca-managed. `worker` — Orca-managed, not the team lead. `lead` — the
team lead, and the only role that receives the coordinator payload. Only Claude Code
leads; a Codex session receives the everyone-payload whatever its role resolves to.
