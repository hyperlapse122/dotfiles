# pi — reference

Every flag below is from `pi --help` on this host; the behaviours called out as
verified were run against the live CLI.

| | |
|---|---|
| Source | `earendil-works/pi`, GitHub release tarball → `~/.local/share/pi/versions/<tag>`; `~/.local/bin/pi` is symlinked at the newest by `.chezmoiscripts/00-tools/run_onchange_after_pi.sh.tmpl` (a whole-dir distribution — the binary resolves sibling `package.json` / `theme/` / `.wasm`, so it cannot be a lone binary) |
| Auth / defaults | `~/.pi/agent/auth.json` is pi-LIVE-WRITTEN: static 1Password-backed API keys for **`kimi-coding` and `zai` ONLY** are merged in by `config-pi-auth`, while pi owns OAuth entries. `config-pi` merges the repo default `openai-codex/gpt-5.6-sol` at `max` plus the declared subagent defaults. Both data sources live under `agents.pi` in `.chezmoidata/agents.yaml`. |
| Canonical | `pi -p --model zai/glm-5.2 --no-session "<brief>"` |
| Strength | Cheapest/fastest of the four with the explicit Z.ai model above; cleanest stdout (the answer, nothing else) |

**`--model` is optional.** Omitting it uses the repo-configured OAuth-backed
`openai-codex/gpt-5.6-sol` default. Keep the explicit Z.ai model in the canonical
bulk-analysis command when cost/speed is the reason for selecting pi.

## Flags

| Flag | Meaning |
|---|---|
| `-p`, `--print` | **Boolean.** Non-interactive: process the prompt and exit. Prompt is **positional**. |
| `--model <pattern>` | `provider/id`, optionally `:<thinking>`. See catalog. |
| `--provider <name>` | Provider alone. Pi's built-in default is `google`, but repo settings override it to OAuth-backed `openai-codex`. |
| `--mode text\|json\|rpc` | Output mode; `text` is the default. |
| `--thinking <level>` | `off` `minimal` `low` `medium` `high` `xhigh` `max` |
| `--no-session` | Ephemeral — write no session file. Use for one-shot delegation. |
| `--session-id <id>` / `--session <path\|id>` | Exact / fuzzy session. |
| `-c`, `--continue` · `-r`, `--resume` · `--fork <path\|id>` | Resume flows. |
| `-nt`, `--no-tools` | Disable **all** tools — the read-only posture. |
| `-nbt`, `--no-builtin-tools` | Drop built-ins, keep extension/custom tools. |
| `-t`, `--tools <list>` | Comma-separated **allowlist**. |
| `-xt`, `--exclude-tools <list>` | Comma-separated **denylist**. |
| `-nc`, `--no-context-files` | Skip `AGENTS.md` / `CLAUDE.md` discovery. |
| `--system-prompt <text>` · `--append-system-prompt <text>` | Replace / extend the system prompt (repeatable; takes text or a file). |
| `--skill <path>` | Load a skill file/dir (repeatable). |
| `-a`, `--approve` | Trust project-local files for this run. |
| `--export <file>` | Export the session to HTML and exit. |
| `--list-models [search]` | Print the catalog. |
| `@files...` | Positional attachments (`pi @spec.md @shot.png "…"`). |

Working directory: **cwd** — there is no `--cd`. `cd <worktree> && pi …`.

## Models (`pi --list-models`)

| Provider | Ids |
|---|---|
| `kimi-coding` | `k2p7` · `kimi-for-coding` · `kimi-k2-thinking` |
| `zai` | `glm-4.5-air` · `glm-4.7` · `glm-5-turbo` · `glm-5.1` · `glm-5.2` (1M ctx) · `glm-5v-turbo` (vision) |
| `anthropic` | `claude-opus-4-8` (Meridian-backed) |
| `openai-codex` | `gpt-5.6-sol` (repo-configured OAuth-backed default) |

Verified working: `zai/glm-5.2`, `kimi-coding/k2p7`; the configured default is `openai-codex/gpt-5.6-sol`.

## Capture

Cleanest stdout of the four — `pi -p` prints the answer and nothing else:

```sh
pi -p --model zai/glm-5.2 --no-session "<brief>" > "$scratch/pi.md"
```

`--mode json` emits JSONL events (`message_end`, `turn_end`, `agent_end`,
`agent_settled`). The assistant text:

```sh
pi -p --mode json --model zai/glm-5.2 --no-session "<brief>" \
  | jq -r 'select(.message) | .message.content[] | select(.type=="text") | .text'
```

## Gotchas

- No `--model` → repo-configured `openai-codex/gpt-5.6-sol` at `max`; requires pi's OAuth entry in the live auth file.
- Bad model id → **exit 1**.
- No working-directory flag. cwd is the whole scope story.
- `--print`/`-p` is a **boolean** here — the opposite of [`agy`](agy.md), and
  unrelated to [`opencode`](opencode.md)'s `-p` (which is `--password`). Do not
  cross-wire the three.
