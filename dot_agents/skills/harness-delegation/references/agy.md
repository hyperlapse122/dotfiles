# agy — reference (Antigravity CLI, the trap harness)

Every flag below is from `agy --help` on this host; the behaviours called out as
verified were run against the live CLI.

| | |
|---|---|
| Source | Antigravity vendor auto-updater manifest (not a GitHub release) → `~/.local/bin/agy` |
| Auth | Antigravity's own login |
| Canonical | `agy --model gemini-pro-agent --print-timeout 20m -p "<brief>"` |
| Strength | Gemini: **1M-token context**, native multimodal (image / pdf / audio / video) |

## GOTCHA #1 — `-p` takes the prompt as its VALUE

Go `flag` parsing. `-p` / `--print` / `--prompt` is **not boolean**:

```sh
agy --model gemini-pro-agent -p "<prompt>"    # CORRECT — flags BEFORE -p
agy -p --model gemini-pro-agent "<prompt>"    # BROKEN — silently
```

The broken form makes `-p`'s value the literal string `--model`; the model id
and the real prompt become stray positionals and are dropped. It does not error
— the agent just starts inspecting its own CLI. **Every flag MUST precede `-p`,
and `-p`'s value MUST be the prompt.**

## Flags

| Flag | Meaning |
|---|---|
| `-p`, `--print`, `--prompt <PROMPT>` | Run one prompt non-interactively and print the response. **Value = the prompt.** |
| `--print-timeout <dur>` | Timeout for print mode. **Default `5m0s`** — raise it for long work or the delegation is cut off. |
| `--model <name\|id>` | Display name **or** id, both accepted. See below. |
| `--mode accept-edits\|plan` | Execution mode. `plan` = the read-only posture. |
| `--sandbox` | Run with terminal restrictions enabled. |
| `--add-dir <DIR>` | Add a directory to the workspace (repeatable). |
| `--dangerously-skip-permissions` | Auto-approve every tool request. **Forbidden without an explicit user request in the same turn.** |
| `-c`, `--continue` · `--conversation <id>` | Resume flows. |
| `--project <id>` · `--new-project` | Project scoping. |
| `--agent <name>` | Agent for the session — **inert here**: `agy agents` lists none on this host. |
| `-i`, `--prompt-interactive` | Prompt, then stay interactive (**not** for delegation). |
| `--log-file <path>` | Override the CLI log path. |

Subcommands: `agent`/`agents`, `models`, `changelog`, `install`, `plugin`/`plugins`, `update`, `help`.

## Models — `--model` takes a display name OR an id, and the ids are a SUPERSET

`agy models` prints **display names** only — that is the catalog the CLI shows
you, not the set it accepts:

> Gemini 3.5 Flash (Low / Medium / High) · Gemini 3.1 Pro (Low / High) ·
> Claude Sonnet 4.6 (Thinking) · Claude Opus 4.6 (Thinking) · GPT-OSS 120B (Medium)

`--model` **also** accepts the raw ids — the ones the `google-agy` provider block
of `dot_config/opencode/readonly_opencode.json.tmpl` uses — and that set is
**larger than what `agy models` lists**:

| Id | Note |
|---|---|
| `gemini-3.5-flash-extra-low` · `gemini-3.5-flash-low` · `gemini-3-flash` · `gemini-3-flash-agent` | Flash tiers (thinking budget ascending) |
| `gemini-3.1-pro-low` · `gemini-pro-agent` | Pro tiers — `gemini-pro-agent` is the high one |
| `gemini-2.5-pro` | **Works, but `agy models` does not list it.** |
| `claude-sonnet-4-6` · `claude-opus-4-6-thinking` | |
| `gpt-oss-120b-medium` | |

Verified accepted: `"Gemini 3.1 Pro (High)"`, `gemini-pro-agent`, `gemini-3-flash`,
`gemini-2.5-pro`, `claude-opus-4-6-thinking`. Do **not** infer that a display
name and an id are interchangeable labels for a 1:1 catalog — when in doubt run
`agy models` for what is offered, and take the id list above for what is
*accepted*. An **unknown model prints the catalog and exits 1.**

## Capture

Plain assistant text on stdout. **No JSON mode.**

```sh
agy --model gemini-pro-agent --print-timeout 20m -p "<brief>" > "$scratch/agy.md"
```

## Gotchas

- Flag order (above). The #1 way to waste a delegation.
- `--print-timeout` default 5m silently truncates long runs.
- `--agent` is inert — no agents are registered on this host.
- No JSON output, so no structured parse. Ask for a shape in the prompt instead.
- No `--cd`: scope via cwd + `--add-dir`.
- `-p` is the prompt's flag here — unlike [`pi`](pi.md) (boolean print),
  [`codex`](codex.md) (`--profile`), and [`opencode`](opencode.md) (`--password`).
