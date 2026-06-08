# codex/

Tracked, shared **OpenAI Codex** settings for this dotfiles repo.

Two files with **two different delivery mechanisms**, because Codex treats them
differently:

- `codex-config.managed.toml` is **merged** into `~/.codex/config.toml` by the
  bootstrap renderer [`scripts/bootstrap/configure-codex-config.mjs`](../scripts/bootstrap/configure-codex-config.mjs)
  (wrappers: `configure-codex-config.sh` / `.ps1`) — Codex writes machine-local
  state back into `config.toml`, so it can't be a symlink.
- `hooks.json` is **symlinked** to `~/.codex/hooks.json` by dotbot — Codex never
  writes back to it, so a plain symlink is safe (and live edits propagate
  without re-running bootstrap).

## Contents

| File | Purpose |
|---|---|
| `codex-config.managed.toml` | The shared Codex settings, as constrained "simple TOML" (one `key = value` per line under standard `[table]` headers). Edit this to change what every machine gets. Ships all-commented (a no-op) by default. |
| `hooks.json` | [Codex lifecycle hooks](https://developers.openai.com/codex/hooks) that pulse the MX Master 4 mouse via the `mxm4-haptic` client. Symlinked to `~/.codex/hooks.json` on Linux + macOS. See **Haptic hooks** below. |

## Why a renderer instead of a dotbot symlink

Codex writes machine-local state back into `~/.codex/config.toml` itself — most
importantly per-project trust decisions under `[projects."<path>"]` — and has no
`include`/import directive to merge a separate tracked file in. A symlink would
let Codex mutate this repo on every "trust this folder?" prompt.

So `codex-config.managed.toml` holds **only** the shared keys, and the renderer
merges them into `$CODEX_HOME/config.toml` (default `~/.codex/config.toml`) with
targeted, TOML-safe edits, **preserving** every machine-local byte (the
`[projects]` trust table and anything else you or Codex added). It runs as a
shared `install.conf.yaml` `shell:` step on every OS, is idempotent, backs up to
`config.toml.bak` before changing, and aborts rather than corrupt an ambiguous
multi-line value.

Run it manually with `scripts/bootstrap/configure-codex-config.sh` (or `.ps1`);
`--check` / `--print` / `--no-backup` are supported.

## Editing the managed settings

- Keep it "simple TOML": one single-line `key = value` per line under standard
  `[table]` / `[table.sub]` headers; `#` comments and blank lines are ignored.
- Do **not** declare a `[projects]` table here — that namespace is machine-local
  trust state the renderer must never overwrite.
- The renderer only **adds/updates** keys. Deleting a line here does **not**
  remove that key from `~/.codex/config.toml`; drop unwanted keys from the live
  file by hand.

See the header of [`codex-config.managed.toml`](./codex-config.managed.toml) for
the full format notes, and the repo-root [`AGENTS.md`](../AGENTS.md) for the
rationale in the agent contract.

## Haptic hooks

[`hooks.json`](./hooks.json) is the Codex counterpart of the
[`@h82/opencode-mxm4-haptic`](../packages/opencode-mxm4-haptic/) OpenCode plugin:
it pulses the MX Master 4's built-in haptics on Codex lifecycle events so you can
*feel* an agent run finish or ask for a decision. Each hook shells out to the
[`mxm4-haptic`](../crates/mxm4-haptic/) client (`~/.local/bin/mxm4-haptic`), which
forwards a waveform to the running `mxm4-hapticd` daemon.

| Codex event | Waveform | Meaning |
|---|---|---|
| `Stop` (a turn ends) | `COMPLETED` | The agent finished and is waiting on you. Only `Stop` is hooked (not `SubagentStop`), so sub-agents don't buzz — mirroring the plugin's root-session-only gating. |
| `PermissionRequest` | `RINGING` | The agent is waiting on you to approve something — answer it. Covers the plugin's `permission.updated` **and** `Question`-tool rings. |

Codex has no error-lifecycle hook, so the plugin's `session.error → MAD` pulse
has no Codex analog and is intentionally omitted.

Each command is guarded with `|| true` and a 5 s `timeout`, so a missing client
(e.g. on a machine where the daemon isn't installed) or a down daemon never fails
or stalls a Codex turn.

### Setup

- **Linked on Linux + macOS only.** [`../install.linux.yaml`](../install.linux.yaml)
  and [`../install.macos.yaml`](../install.macos.yaml) symlink
  `~/.codex/hooks.json → codex/hooks.json`. Windows is excluded — the
  `mxm4-haptic` client isn't built there.
- **Trust it once.** Codex requires reviewing and trusting non-managed command
  hooks before they run. After the first link (or any edit to `hooks.json`), run
  `/hooks` in the Codex CLI and trust the two hooks. Codex records trust against
  the hook's hash, so editing the file marks it for re-review.
- **Daemon must be running.** The hooks are no-ops (pulse skipped) unless
  `mxm4-hapticd` is up — `systemctl --user status mxm4-hapticd.service` (Linux)
  or the launchd agent (macOS). See the root [`AGENTS.md`](../AGENTS.md) "Solaar
  haptic playback (MX Master 4)" section.
