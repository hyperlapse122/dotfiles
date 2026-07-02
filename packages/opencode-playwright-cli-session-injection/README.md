# @h82/opencode-playwright-cli-session-injection

An [OpenCode](https://opencode.ai) **plugin** that sets a default
[`playwright-cli`](https://github.com/microsoft/playwright) browser session for
every shell command OpenCode spawns, derived from the current working directory.
It injects `PLAYWRIGHT_CLI_SESSION` into the shell environment so that all
`playwright-cli` invocations within one project share a single isolated,
persistent browser session — and different projects stay isolated from each
other automatically.

It is a thin event handler: it hooks OpenCode's `shell.env` and writes one
environment variable. No process is spawned, no browser is touched — the actual
session lifecycle is owned by `playwright-cli` itself.

## What it does

The plugin registers a `shell.env` hook. For every shell command OpenCode runs
with a working directory, it sets:

```
PLAYWRIGHT_CLI_SESSION = opencode-<hash8>
```

where `<hash8>` is the first 8 hex characters of the SHA-1 digest of the
raw `cwd` string, computed with `node:crypto`'s `createHash("sha1")`. For
example, a command run in `/home/h82/dotfiles` yields `opencode-2e1002b8`.

Hashing keeps the session name short and fixed-length regardless of how deep the
project path is, while staying deterministic per directory (so the same project
always maps to the same session) and distinct across directories (so different
projects stay isolated).

`playwright-cli` reads `PLAYWRIGHT_CLI_SESSION` as the default value of its `-s`
(session) flag, so every `playwright-cli` command OpenCode launches in a given
project transparently targets the same named browser session. Because each
named session has independent cookies, local/session storage, IndexedDB, cache,
history, and tabs, this gives you:

- **Per-project persistence** — a login or page state established in one
  `playwright-cli` run is still there on the next run within the same project.
- **Cross-project isolation** — a different project directory derives a
  different session name, so its browser state never bleeds across.

When a command has no `cwd`, the hook does nothing and `playwright-cli` falls
back to its own default session.

See [`src/index.ts`](src/index.ts) — the env var name and the hash are the
only logic.

## Status

- **Platform**: cross-platform. The plugin only writes an environment variable,
  so it works wherever OpenCode and `playwright-cli` run (Linux, macOS,
  Windows).
- **Runtime**: the OpenCode Node runtime that loads the plugin (`node >= 24`).
- **Not published.** The `@h82/` scope is a naming namespace, not a registry
  target; this is a workspace-local plugin built in place. Chezmoi symlinks
  the built file into OpenCode's plugin directory so it auto-loads (see
  "Enabling it in OpenCode" below).

## Install / build

This package is a member of the `@h82/dotfiles` Yarn workspace rooted at
[`../`](../) (see [`../README.md`](../README.md)). Install once from the
workspace root; build from the root via a selector or from this directory.

```sh
# from the workspace root (packages/)
yarn install --immutable                                                  # restore deps (single root yarn.lock)
yarn workspace @h82/opencode-playwright-cli-session-injection build       # tsdown -> dist/index.mjs + dist/index.d.mts
yarn workspace @h82/opencode-playwright-cli-session-injection typecheck   # tsc --noEmit
yarn workspace @h82/opencode-playwright-cli-session-injection lint        # eslint .
yarn workspace @h82/opencode-playwright-cli-session-injection format      # prettier --write .

# or from this directory (packages/opencode-playwright-cli-session-injection/)
yarn build
yarn lint && yarn format:check
```

The package is ESM-only (`"type": "module"`) and builds with
[`tsdown`](https://tsdown.dev) (Rolldown-based), configured in
[`tsdown.config.ts`](tsdown.config.ts):

- `@opencode-ai/plugin` is **never bundled** (`neverBundle`) — it is a
  type-only/host-provided peer supplied by the OpenCode runtime that loads the
  plugin. The plugin has no other runtime dependencies.

Build output is `dist/index.mjs` (ESM) + `dist/index.d.mts`.

## Enabling it in OpenCode

**Chezmoi enables it automatically on Linux and macOS.**
The `.chezmoiscripts/build/run_onchange_after_build-opencode-plugins.sh.tmpl` script symlinks the built file into
OpenCode's auto-load plugin directory:

```
~/.config/opencode/plugins/playwright-cli-session-injection.js -> packages/opencode-playwright-cli-session-injection/dist/index.mjs
```

OpenCode scans top-level `*.ts` / `*.js` files in `~/.config/opencode/plugin/`
and `~/.config/opencode/plugins/` (singular and plural) and loads them at
startup. No `opencode.json` `plugin` array entry is needed. We deliberately
name the symlink `playwright-cli-session-injection.js` (not `.mjs`) because
`.mjs` is not part of that auto-scan glob. The `.js` name points at the ESM
`dist/index.mjs` output, and the sibling `.js.map` symlink supplies the
sourcemap.

This link is created by chezmoi on both Linux and macOS. However, the automated
Yarn build runs on apply only on Linux. On macOS, the symlink will dangle until
you build the workspace manually.

**Manual / cross-platform.** Anywhere chezmoi doesn't link it, add the
built module to your OpenCode config's `plugin` array so the runtime loads it and
picks up its exported `PlaywrightCliSessionInjectionPlugin`:

```jsonc
{
  "plugin": [
    "/home/h82/dotfiles/packages/opencode-playwright-cli-session-injection/dist/index.mjs"
  ]
}
```

See the OpenCode [plugin docs](https://opencode.ai/docs/plugins/) for the
supported plugin reference forms (local path vs. package). Rebuild
(`yarn workspace @h82/opencode-playwright-cli-session-injection build`) after
editing `src/` for the change to take effect.

## API surface

| Export | Type | Notes |
|---|---|---|
| `PlaywrightCliSessionInjectionPlugin` | `Plugin` (from `@opencode-ai/plugin`) | The plugin entry. Returns a `shell.env` hook that sets `PLAYWRIGHT_CLI_SESSION = opencode-<hash8>` (the first 8 hex chars of the SHA-1 of the raw `cwd` string) on every command that has a `cwd`. |
