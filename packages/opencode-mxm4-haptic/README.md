# @h82/opencode-mxm4-haptic

An [OpenCode](https://opencode.ai) **plugin** that pulses the MX Master 4's
built-in haptics on OpenCode events. When an OpenCode session goes idle (the
agent finished its turn), the mouse gives a tactile "done" buzz — handy for
kicking off a long agent run and feeling, rather than watching, for completion.

It is a thin event handler: it forwards a waveform name to the running
[`mxm4-hapticd`](../../crates/mxm4-haptic/) daemon through the
[`@h82/mxm4-haptic`](../mxm4-haptic/) client. All device I/O, discovery,
debounce, and pacing live in the daemon — this package only maps an OpenCode
event to a waveform.

## What it does

| OpenCode event | Waveform sent | Meaning |
|---|---|---|
| `session.idle` | `COMPLETED` | The agent finished its turn / the session went idle. |

That is the entire behavior today (see [`src/index.ts`](src/index.ts)). Add more
`event.type` branches to react to other OpenCode events.

## Status

- **Platform**: Linux only at runtime — it talks to `mxm4-hapticd`, which owns
  Linux `hidraw` for the MX Master 4. On other OSes there is nothing to pulse.
- **Hardware**: a Logitech **MX Master 4** paired (HID++ feature `0x19B0`).
- **Runtime**: the OpenCode Node runtime that loads the plugin. The bundled
  `@h82/mxm4-haptic` client needs only `node:net` + `$XDG_RUNTIME_DIR`.
- **Not published.** The `@h82/` scope is a naming namespace, not a registry
  target; this is a workspace-local plugin built in place. The Linux bootstrap
  does, however, symlink the built file into OpenCode's plugin directory so it
  auto-loads (see "Enabling it in OpenCode" below).

## Prerequisites

1. The `mxm4-hapticd` user daemon must be **running** — it owns the AF_UNIX
   socket at `$XDG_RUNTIME_DIR/mxm4-haptic.sock` that this plugin writes to:

   ```sh
   systemctl --user status mxm4-hapticd.service
   ```

   If the daemon is down, the pulse is simply skipped (the client rejects with a
   `SocketMissingError`). See the root [`AGENTS.md`](../../AGENTS.md) "Solaar
   haptic playback (MX Master 4)" section and [`../../crates/mxm4-haptic/`](../../crates/mxm4-haptic/)
   for the daemon architecture.

2. The `@h82/mxm4-haptic` client is bundled into the build output, so no runtime
   dependency install is needed beyond the daemon.

## Install / build

This package is a member of the `@h82/dotfiles` Yarn workspace rooted at
[`../`](../) (see [`../README.md`](../README.md)). Install once from the
workspace root; build from the root via a selector or from this directory.

```sh
# from the workspace root (packages/)
yarn install --immutable                          # restore deps (single root yarn.lock)
yarn workspace @h82/opencode-mxm4-haptic build      # tsdown -> dist/index.mjs + dist/index.d.mts
yarn workspace @h82/opencode-mxm4-haptic typecheck  # tsc --noEmit
yarn workspace @h82/opencode-mxm4-haptic lint       # eslint .
yarn workspace @h82/opencode-mxm4-haptic format     # prettier --write .

# or from this directory (packages/opencode-mxm4-haptic/)
yarn build
yarn lint && yarn format:check
```

The package is ESM-only (`"type": "module"`) and builds with
[`tsdown`](https://tsdown.dev) (Rolldown-based), configured in
[`tsdown.config.ts`](tsdown.config.ts):

- `@h82/mxm4-haptic` is **bundled** into the output (`alwaysBundle`) so the
  plugin file is self-contained.
- `@opencode-ai/plugin` is **never bundled** (`neverBundle`) — it is a
  type-only/host-provided peer supplied by the OpenCode runtime that loads the
  plugin.

Build output is `dist/index.mjs` (ESM) + `dist/index.d.mts`.

## Enabling it in OpenCode

**On Linux, the bootstrap enables it automatically.**
[`install.linux.yaml`](../../install.linux.yaml) symlinks the built file into
OpenCode's auto-load plugin directory:

```
~/.config/opencode/plugins/mxm4-haptic.js -> packages/opencode-mxm4-haptic/dist/index.mjs
```

OpenCode scans top-level `*.ts` / `*.js` files in `~/.config/opencode/plugin/`
**and** `~/.config/opencode/plugins/` (singular and plural) and loads them at
startup — no `opencode.json` `plugin` array entry is needed. The symlink is
deliberately named `mxm4-haptic.js` (not `.mjs`) because `.mjs` is **not** part
of that auto-scan glob; the `.js` name points at the ESM `dist/index.mjs`
output, and the sibling `mxm4-haptic.js.map` symlink supplies the sourcemap. This
only happens after the workspace is built, so run the Linux bootstrap (or
`yarn workspace @h82/opencode-mxm4-haptic build`) first.

**Manual / cross-platform.** Anywhere the bootstrap doesn't link it, add the
built module to your OpenCode config's `plugin` array so the runtime loads it and
picks up its exported `MXMaster4HapticPlugin`:

```jsonc
{
  "plugin": [
    "/home/h82/dotfiles/packages/opencode-mxm4-haptic/dist/index.mjs"
  ]
}
```

See the OpenCode [plugin docs](https://opencode.ai/docs/plugins/) for the
supported plugin reference forms (local path vs. package). Rebuild
(`yarn workspace @h82/opencode-mxm4-haptic build`) after editing `src/` for the
change to take effect.

## API surface

| Export | Type | Notes |
|---|---|---|
| `MXMaster4HapticPlugin` | `Plugin` (from `@opencode-ai/plugin`) | The plugin entry. Returns an `event` hook that pulses on `session.idle`. |

## Extending

Add branches inside the `event` hook in [`src/index.ts`](src/index.ts), mapping
OpenCode event types to waveform names. The full waveform table (16 names, e.g.
`SHARP COLLISION`, `HAPPY ALERT`, `MAD`) is documented in
[`../mxm4-haptic/README.md`](../mxm4-haptic/README.md). Always `await
sendCommand(...)` — it resolves only after the bytes flush to the daemon.

```ts
event: async ({ event }) => {
  if (event.type === "session.idle") await sendCommand("COMPLETED");
  // e.g. react to other events:
  // if (event.type === "session.error") await sendCommand("MAD");
}
```
