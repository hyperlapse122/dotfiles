# codex — reference

Every flag below is from `codex exec --help` / `codex exec review --help` on this
host; the behaviours called out as verified were run against the live CLI.

| | |
|---|---|
| Source | `openai/codex`, GitHub release archive → `~/.codex/packages/standalone/releases/…`; `~/.local/bin/codex` symlinked by `.chezmoiscripts/00-tools/` |
| Auth | `~/.codex/` (`CODEX_HOME`) — its own login, not this repo's |
| Canonical | `codex exec --sandbox read-only -C <worktree> -o <file> "<brief>"` |
| Review | `codex exec review --uncommitted` |
| Strength | Purpose-built non-interactive **code review**; a real sandbox model |

Subcommand is `codex exec` (alias `codex e`). Prompt is **positional**, or read
from **stdin** when omitted or when `-` is passed. Piped stdin *plus* a prompt
argument → stdin is appended as a `<stdin>` block.

## Flags (`codex exec`)

| Flag | Meaning |
|---|---|
| `-s`, `--sandbox <MODE>` | **The permission model.** `read-only` \| `workspace-write` \| `danger-full-access` |
| `-m`, `--model <MODEL>` | Model id. |
| `-C`, `--cd <DIR>` | Working root — **use this to target a worktree**. |
| `--add-dir <DIR>` | Extra writable dir alongside the workspace. |
| `--skip-git-repo-check` | Required to run outside a git repo. |
| `-o`, `--output-last-message <FILE>` | **Write the final answer to a file.** The capture mechanism. |
| `--json` | Print events to stdout as JSONL. |
| `--output-schema <FILE>` | Constrain the final response to a JSON Schema. |
| `-c key=value` | Override a `config.toml` value (dotted path; value parsed as TOML). |
| `-p`, `--profile <NAME>` | Layer `$CODEX_HOME/<name>.config.toml` on the base config. |
| `--enable <F>` / `--disable <F>` | Feature toggles (repeatable). |
| `-i`, `--image <FILE>...` | Attach image(s) to the prompt. |
| `--ephemeral` | Persist no session files to disk. |
| `--ignore-user-config` · `--ignore-rules` | Skip `config.toml` / execpolicy `.rules`. |
| `--color always\|never\|auto` | — |
| `--dangerously-bypass-approvals-and-sandbox` | Skips approvals **and** sandbox. **Forbidden without an explicit user request in the same turn.** |
| `--dangerously-bypass-hook-trust` | Runs hooks with no persisted trust. Same prohibition. |

`codex exec resume --last` resumes the most recent session.

## `codex exec review` — purpose-built non-interactive code review

| Flag | Meaning |
|---|---|
| `[PROMPT]` | Custom review instructions (positional; `-` = stdin). |
| `--uncommitted` | Review staged + unstaged + untracked changes. |
| `--base <BRANCH>` | Review this branch's changes against a base. |
| `--commit <SHA>` | Review the changes a single commit introduced. |
| `--title <TITLE>` | Commit title to show in the review summary. |
| `-m`, `--model` · `-c` · `--enable`/`--disable` | As above. |

This is the first thing to reach for on "get a second opinion on my diff".

## Capture

```sh
codex exec --sandbox read-only -C "$wt" -o "$scratch/codex.md" "<brief>"
cat "$scratch/codex.md"
```

**Do not scrape stdout.** It carries a banner and a `tokens used` footer, and
MCP servers spew on stderr — observed verbatim:
`ERROR rmcp::transport::worker: worker quit with fatal: Unexpected content type`.
That is **noise, not failure**. `-o` writes the final message and nothing else.

`--json` emits a JSONL event stream when you need structure instead.

## Gotchas

- **There is NO `--full-auto` flag in this build.** Do not write one. Editing =
  `--sandbox workspace-write`.
- Bad model id → **exit 1**.
- Outside a git repo, `--skip-git-repo-check` is mandatory or it refuses.
- The two `--dangerously-*` flags are guardrail-gated (core AGENTS.md).
- `-p` here is `--profile` — not print, not password. Do not cross-wire with
  [`pi`](pi.md) / [`agy`](agy.md) / [`opencode`](opencode.md).
