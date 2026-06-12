# codex/

Tracked, shared **OpenAI Codex** settings for this dotfiles repo.

[`codex-config.managed.toml`](./codex-config.managed.toml) holds the shared
settings — scalar keys **and** the MX Master 4 haptic lifecycle hooks. The
bootstrap renderer
[`scripts/bootstrap/configure-codex-config.mjs`](../scripts/bootstrap/configure-codex-config.mjs)
(run on **Bun**; wrappers: `configure-codex-config.sh` / `.ps1`) **merges** it
into `~/.codex/config.toml`. It can't be a dotbot symlink: Codex writes
machine-local state back into `config.toml` (per-project `[projects]` trust, the
`[[hooks.*]]` entries it manages for plugins), so the renderer applies only the
declared settings and preserves everything else.

## Contents

| File | Purpose |
|---|---|
| `codex-config.managed.toml` | The shared Codex settings — scalar keys plus the `[[hooks.*]]` MX Master 4 haptic lifecycle hooks. Full TOML, parsed by Bun. Edit this to change what every machine gets. |

## Why a renderer instead of a dotbot symlink

Codex writes machine-local state back into `~/.codex/config.toml` itself — most
importantly per-project trust decisions under `[projects."<path>"]`, plus the
`[[hooks.*]]` entries it manages for installed plugins. A symlink would let Codex
mutate this repo on every "trust this folder?" prompt, and Codex has no
`include`/import directive to merge a separate tracked file in.

So `codex-config.managed.toml` holds **only** the shared settings, and the
renderer merges them into `$CODEX_HOME/config.toml` (default
`~/.codex/config.toml`) two ways, **preserving** every machine-local byte:

- **Scalar keys** (root scalars and scalar keys under `[table]` headers) get
  targeted, TOML-safe edits — updated in place when present, else inserted
  (root keys before the first table header; sub-table keys inside their table).
- **Array-of-tables** (the `hooks` block) are re-serialized and written as one
  sentinel-fenced managed block (`# >>> managed … >>>` / `# <<< … <<<`),
  appended at EOF and replaced in place on every re-run. Array-of-tables are
  valid at EOF after the `[projects]` trust table, which sidesteps TOML's
  "root keys must precede every table header" rule.

It runs as a shared `install.conf.yaml` `shell:` step on every OS through
mise-managed **Bun** (whose built-in `Bun.TOML.parse` reads the managed file),
is idempotent, backs up to `config.toml.bak` before changing, and aborts rather
than corrupt an ambiguous multi-line value.

Run it manually with `scripts/bootstrap/configure-codex-config.sh` (or `.ps1`);
`--check` / `--print` / `--no-backup` are supported.

## Editing the managed settings

- It's **full TOML** (parsed by Bun's `Bun.TOML.parse`): scalars, nested
  `[table]` / `[table.sub]` headers, inline arrays, and array-of-tables
  (`[[a.b]]`, as the hooks use) are all valid.
- Do **not** declare a `[projects]` table here — that namespace is machine-local
  trust state the renderer refuses to manage.
- The renderer only **adds/updates**. Deleting a scalar line here does **not**
  remove that key from `~/.codex/config.toml`, and removing the hooks block does
  **not** delete an already-written managed block; drop unwanted keys/blocks from
  the live file by hand.

See the header of [`codex-config.managed.toml`](./codex-config.managed.toml) for
the full format notes, and the repo-root [`AGENTS.md`](../AGENTS.md) for the
rationale in the agent contract.

## Haptic hooks

The `[[hooks.Stop]]` / `[[hooks.PermissionRequest]]` entries in
[`codex-config.managed.toml`](./codex-config.managed.toml) are the Codex
counterpart of the
[`@h82/opencode-mxm4-haptic`](../packages/opencode-mxm4-haptic/) OpenCode plugin:
they pulse the MX Master 4's built-in haptics on Codex lifecycle events so you can
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

In Codex's hook schema each event is an **array of matcher-groups**
(`[[hooks.Stop]]`), and each group carries a `hooks` array of handlers
(`[[hooks.Stop.hooks]]`); `Stop` / `PermissionRequest` ignore the matcher, so each
group is unfiltered. The renderer appends our group at EOF, so it coexists with
any `[[hooks.Stop]]` Codex or another plugin already wrote — Codex runs every
matching group, so both fire.

### Setup

- **Merged on every OS; active on Linux + macOS.** The shared `install.conf.yaml`
  step merges the hooks into `~/.codex/config.toml` on all platforms, but the
  `mxm4-haptic` client is only built on Linux + macOS — on Windows the guarded
  command is a harmless no-op (the binary isn't there).
- **Trust it once.** Codex requires reviewing and trusting non-managed command
  hooks before they run. After the hooks first land in `config.toml` (or any edit
  to them), run `/hooks` in the Codex CLI and trust the two hooks. Codex records
  trust against the hook's hash, so editing them marks them for re-review.
- **Daemon must be running.** The hooks are no-ops (pulse skipped) unless
  `mxm4-hapticd` is up — `systemctl --user status mxm4-hapticd.service` (Linux)
  or the launchd agent (macOS). See the root [`AGENTS.md`](../AGENTS.md) "Solaar
  haptic playback (MX Master 4)" section.
