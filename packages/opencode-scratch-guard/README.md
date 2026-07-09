# @h82/opencode-scratch-guard

An [OpenCode](https://opencode.ai) **plugin** that makes the repository's
temporary-file policy self-enforcing. It does two things:

1. **Injects a per-user scratch dir as `$TMPDIR`** into every shell command, so
   `mktemp` and any `TMPDIR`-aware tool default their scratch to a per-user
   location instead of the shared system temp.
2. **Denies the shared system temp** (`/tmp`, `/var/tmp`, `/dev/shm`) for the
   `bash`, `write`, `edit`, and `read` tools, aborting the tool call with an
   actionable message that points at `$TMPDIR`.

This mirrors the [`AGENTS.md`](../../dot_config/opencode/readonly_AGENTS.md)
"Temporary / scratch files" rule for agents that keep reaching for `/tmp`
anyway — the policy stops being advisory and becomes a hard gate.

## Why

`AGENTS.md` says the shared system temp is denied and every operation on it must
fail; agents should use a per-user dir (`$XDG_RUNTIME_DIR`, macOS `$TMPDIR`,
Windows `%TEMP%`) in a task-scoped subdir such as `$XDG_RUNTIME_DIR/agent-scratch`.
Documenting the rule is not enough — models still emit `/tmp/foo.txt`. This
plugin removes the friction (the correct dir is already `$TMPDIR`) **and** closes
the gap (a `/tmp` access is refused, not silently honored).

## What it does

### `shell.env` — inject `$TMPDIR`

For every shell command OpenCode runs, the plugin sets:

```
TMPDIR = <scratch dir>          # + TEMP / TMP on Windows
```

where `<scratch dir>` is `<base>/agent-scratch` and `<base>` is:

| Platform | Base (preferred → fallback) |
|---|---|
| Linux | `$XDG_RUNTIME_DIR` → `~/.cache` |
| macOS | `$TMPDIR` → `~/.cache` |
| Windows | `%TEMP%` / `%TMP%` → `%USERPROFILE%\AppData\Local\Temp` |

The fallback is deliberately **not** `os.tmpdir()`, which returns `/tmp` on
Linux. The dir is created (mode `0700`) when the plugin loads.

### `tool.execute.before` — deny the shared system temp

| Tool | Checked | Blocked when |
|---|---|---|
| `bash` | `command` | a denied root appears as an absolute path token (`/tmp`, `/tmp/x`, `>/tmp`, `TMPDIR=/tmp` …) |
| `write` / `edit` / `read` | `filePath` (`path` / `file_path`) | the path resolves to a location at or under a denied root |

The bash matcher is token-aware: it ignores `$TMPDIR`, `./tmp`, `/home/x/tmp`,
and `/tmpfs` (look-alikes), and only flags a denied root that starts an absolute
path. Denied roots are `/tmp`, `/var/tmp`, `/dev/shm` (plus the `/private/…`
realpath aliases on macOS); Windows guards nothing, since `%TEMP%` is already
per-user.

In `enforce` mode the hook **throws**, which aborts the tool and surfaces the
reason to the model. In `warn` mode it attaches the reason to `output.message`
and lets the call through.

## Modes

Set `OPENCODE_SCRATCH_GUARD` in the environment that launches OpenCode (it is
read once at load; an agent cannot flip it from inside a shell command):

| Value | `$TMPDIR` injection | Deny guard |
|---|---|---|
| unset / `enforce` (default) | on | **throws** (hard block) |
| `warn` | on | soft warning via `output.message` |
| `off` / `0` / `false` | off | off (plugin is a no-op) |

`warn` is the escape hatch for a rare false positive (e.g. `grep -r /tmp .`
searching for the literal string): flip to `warn`, or `off`, without editing the
plugin.

## Install / build

Member of the `@h82/dotfiles` Bun workspace rooted at [`../`](../) (see
[`../README.md`](../README.md)).

```sh
# from the workspace root (packages/)
cd packages
vp install --frozen-lockfile           # restore deps (single root bun.lock)
vp run -r build                        # vp pack across all members
vp run -r typecheck                    # tsc --noEmit
vp run -r test                         # Vitest (pure helpers + hook integration)
vp check                               # format + lint + type-check (whole workspace)

# or build/test just this member:
cd opencode-scratch-guard
vp pack && vp test
```

ESM-only (`"type": "module"`), built with `vp pack` (tsdown under the hood,
configured in the `pack` block of [`vite.config.ts`](vite.config.ts)):
`@opencode-ai/plugin` is `neverBundle` (a type-only, host-provided peer); the
plugin has no other runtime dependencies (only Node builtins). Output is
`dist/index.mjs` + `dist/index.d.mts`.

## Enabling it in OpenCode

**Chezmoi enables it automatically on Linux and macOS.** The
[`.chezmoiscripts/build/run_onchange_after_build-opencode-plugins.sh.tmpl`](../../.chezmoiscripts/build/run_onchange_after_build-opencode-plugins.sh.tmpl)
script symlinks the built file into OpenCode's auto-load plugin directory:

```
~/.config/opencode/plugins/scratch-guard.js -> packages/opencode-scratch-guard/dist/index.mjs
```

OpenCode auto-scans top-level `*.ts` / `*.js` (not `*.mjs`) files under
`~/.config/opencode/plugin/` and `plugins/`, so the link is named
`scratch-guard.js` but targets the ESM `dist/index.mjs`, with a sibling
`scratch-guard.js.map` for stack traces. Cross-platform (like the
playwright-cli-session-injection plugin), so it is linked on both Linux and
macOS. The automated Bun build runs on apply only on Linux; on macOS the symlink
dangles until you build the workspace manually.

**Manual / cross-platform.** Anywhere chezmoi doesn't link it, add the built
module to your OpenCode config's `plugin` array so the runtime loads its exported
`ScratchGuardPlugin`:

```jsonc
{
  "plugin": [
    "/home/h82/dotfiles/packages/opencode-scratch-guard/dist/index.mjs"
  ]
}
```

## API surface

| Export | Type | Notes |
|---|---|---|
| `ScratchGuardPlugin` | `Plugin` (from `@opencode-ai/plugin`) | The plugin entry. Registers `shell.env` (`$TMPDIR` injection) and `tool.execute.before` (deny guard); a no-op when `OPENCODE_SCRATCH_GUARD=off`. |
| `parseMode` | `(raw: string \| undefined) => GuardMode` | Parse the mode env var. |
| `deniedRoots` | `(platform?) => readonly string[]` | The shared-temp roots denied on a platform. |
| `computeScratchDir` | `(env, platform, home) => string` | The `<base>/agent-scratch` path injected as `$TMPDIR`. |
| `isDeniedPath` | `(filePath, platform, baseDir) => boolean` | Whether a file path resolves under a denied root. |
| `makeBashDenyRegex` | `(platform?) => RegExp \| null` | The token-aware matcher for denied roots in a shell command. |
