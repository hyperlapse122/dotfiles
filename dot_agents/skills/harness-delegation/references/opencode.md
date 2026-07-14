# opencode — reference

Every flag below is from `opencode run --help` on this host; the behaviours
called out as verified were run against the live CLI.

| | |
|---|---|
| Source | `anomalyco/opencode`, GitHub release archive → `~/.local/bin/opencode` |
| Auth / config | Repo-managed **readonly** `~/.config/opencode/opencode.json`; provider data comes from `.chezmoidata/agents.yaml`, `op://` references resolve from 1Password at render, and POSIX Anthropic routes through the local Meridian service |
| Canonical | `opencode run --agent <Agent> --dir <worktree> "<brief>"` |
| Strength | The **agent roster** — plan → execute → critique as distinct agents |

## Flags (`opencode run`)

| Flag | Meaning |
|---|---|
| `[message..]` | The prompt (positional). |
| `--agent <name>` | **The main dial.** See the roster. |
| `-m`, `--model provider/model` | Override the agent's model. |
| `--variant <high\|max\|minimal\|…>` | Provider-specific reasoning effort. |
| `--format default\|json` | `json` = raw JSONL event stream. |
| `--dir <path>` | **Working directory — use this to target a worktree.** |
| `-f`, `--file <path>` | Attach file(s). |
| `-c`, `--continue` · `-s`, `--session <id>` · `--fork` | Resume flows (`--fork` needs one of the first two). |
| `--auto` | Auto-approve permissions not explicitly denied. Rarely needed here (see below). |
| `--pure` | Run without external plugins. |
| `--share` · `--title <t>` | Session sharing / naming. |
| `--attach <url>` | Drive a running `opencode serve`. |
| `--thinking` | Show thinking blocks. |
| `--print-logs` · `--log-level` | Diagnostics to stderr. |

## Agents (`opencode agent list`)

From the **oh-my-openagent plugin**, not base opencode:

| Kind | Agents |
|---|---|
| Primary | `Sisyphus` (ultraworker — the default) · `Hephaestus` (Deep Agent) · `Prometheus` (Plan Builder) · `Atlas` (Plan Executor) |
| Subagent | `explore` · `general` · `plan` · `build` · `librarian` · `oracle` · `Metis` (Plan Consultant) · `Momus` (Plan Critic) · `multimodal-looker` · `Sisyphus-Junior` |

A plan → execute → critique chain is `Prometheus` → `Atlas` → `Momus`;
`oracle` is the deep-reasoning second opinion.

## Model selection is NOT `opencode.json`'s top-level `model`

A plain `opencode run` does **not** use the top-level `model` key.
oh-my-openagent maps a model per agent/category from `.chezmoidata/agents.yaml` (`agents.opencode.ohMyOpenagent`)
— a verified default run reported `Sisyphus - ultraworker · claude-opus-4-8`.
**Pick the agent**; override `-m` only when you specifically want a different
model.

## Capture

```sh
opencode run --agent oracle --dir "$wt" "<brief>" > "$scratch/oc.md"
```

`--format json` emits a JSONL event stream; the assistant text arrives in events
shaped `{"type":"text", …, "part":{"text":"…"}}`:

```sh
opencode run --format json --agent oracle --dir "$wt" "<brief>" \
  | jq -r 'select(.type=="text") | .part.text'
```

## Gotchas

- **Meridian-backed Anthropic.** `anthropic/*` requests route through the local
  Meridian service at `http://127.0.0.1:3456`; its stable OpenCode plugin path is
  `~/.local/share/meridian/current/plugin/meridian.ts`. A delegation can hang or
  return empty when the proxy or Claude authentication is unavailable. Check
  `curl -fsS http://127.0.0.1:3456/health` and, on Linux,
  `systemctl --user status meridian.service`.
- `--auto` is **rarely needed**: permissions are already configured in the
  repo-managed readonly `opencode.json` (bash `*` allowed; edits allowed except
  denied credential paths and `/tmp`, `/var/tmp`, `/dev/shm`), and the
  `scratch-guard` plugin enforces the temp-file policy.
- **Never write delegate output to `/tmp`, `/var/tmp`, `/dev/shm`** — the core
  temp-file rule, and `scratch-guard` actively denies those paths anyway.
- Bad model id → **exit 1**.
- `-p` here is `--password` (basic auth), **not** print. Do not cross-wire with
  [`pi`](pi.md) / [`agy`](agy.md) / [`codex`](codex.md).
