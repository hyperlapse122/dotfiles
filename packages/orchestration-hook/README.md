# @h82/orchestration-hook

Delivers this checkout's orchestration payload to an agent session, and refuses shell
launches of other agent CLIs while Orca manages that session.

Compiles to a single standalone binary staged at `~/.local/libexec/orchestration-hook`.
Each harness's plugin `hooks.json` invokes it by absolute path, so the delivery path
depends on no shell, no `jq`, and no `bun` on `PATH`.

## Commands

| Command | Purpose |
| --- | --- |
| `orchestration-hook hook --harness <claude\|codex\|agy>` | The delivery handler. Writes one envelope on stdout and always exits 0. |
| `orchestration-hook guard --harness <claude\|codex\|agy>` | The launch gate. Writes one decision document on stdout and always exits 0. |
| `orchestration-hook print-payload --body <everyone\|coordinator>` | Prints an embedded payload body. The parity gate compares it against the source body. |
| `orchestration-hook role` | Prints the resolved session role and the three environment inputs it read. |
| `orchestration-hook --version` | Prints the build identifier. |

`hook` and `guard` are the subcommands that fail open: any error, unknown flag, or
unparsable argument still yields that harness's no-op output and exit 0. A delivery hook
that errors delays session start, and a gate that errors breaks every tool call in the
session — both worse than the thing the hook failed to do. Every other subcommand uses
ordinary CLI conventions: diagnostics on stderr, non-zero exit on error.

## Delivery shapes

Claude Code and Codex have a session-start event and read a `SessionStart` envelope.
Antigravity has none: its hook fires before every model invocation and reads a document
of steps to inject, so the whole envelope rides in one ephemeral step and is re-injected
each time. That repetition is the cost of never leaving a lead holding half a rule set —
an envelope that could not be composed at one opportunity lands whole at the next.

The gate answers in each harness's own decision document. It denies in that shape and
otherwise says nothing at all: on Antigravity an explicit allow would override that
harness's own permission prompt, turning a launch gate into blanket auto-approval.

## Payload bodies

The two bodies in `.chezmoitemplates/` are the single source. `src/payload.ts` embeds
them at build time, and chezmoi renders the same files for omp's instruction file, which
has no injection point of any kind. Neither body may contain template actions: the build
embeds raw bytes and does not render.

## Roles

`none` — not Orca-managed. `worker` — Orca-managed, not the team lead. `lead` — the team
lead, and the only role that receives the coordinator payload. Lead eligibility follows
the role alone: every served harness leads on the same terms.
