# @h82/mxm4-haptic

A tiny, zero-runtime-dependency **TypeScript client** for the `mxm4-hapticd`
daemon. It sends MX Master 4 haptic waveform commands over the daemon's IPC
endpoint — an AF_UNIX socket on Unix (`$XDG_RUNTIME_DIR/mxm4-haptic.sock` on
Linux, `$TMPDIR/mxm4-haptic.sock` on macOS) and the `\\.\pipe\mxm4-haptic` named
pipe on Windows (Node's `net` does local IPC via named pipes there). The
resolver mirrors the Rust daemon's `socket_path()`: Windows → that pipe; Unix →
`XDG_RUNTIME_DIR` → `TMPDIR` → `/tmp`.

It mirrors the portable client surface of the Rust crate
[`../../crates/mxm4-haptic/src/lib.rs`](../../crates/mxm4-haptic/src/lib.rs). It
does **not** touch hidraw, does **not** do device discovery, and does **not**
replace the daemon — all device I/O, debounce, queueing, and pacing live in
`mxm4-hapticd`. This is purely the "hand a waveform name to the daemon" half.

> The latency-critical Solaar hot path still uses the Rust `mxm4-haptic` client
> binary. This library is for **Node/Bun** consumers (scripts, tooling, MCP
> servers, etc.) that want to trigger haptics from a JavaScript runtime.

## Status

- **Runtimes**: tested on **Node ≥24** (developed on Node 24). Works under
  **Bun** via its `node:net` compatibility layer. **Deno is not supported** /
  not claimed.
- **Platform**: Linux + macOS + Windows at runtime — wherever the
  `mxm4-hapticd` daemon runs (the daemon reaches the device via `hidapi`: Linux
  hidraw, macOS IOKit, Windows native HID). The library itself only needs
  `node:net` + the endpoint (a runtime dir on Unix, the named pipe on Windows),
  but there is nothing for it to talk to unless the daemon is running. (The
  daemon is not bootstrap-built on Windows — see the crate README; build/run it
  manually there.)
- **Dependencies**: zero runtime dependencies (`node:net` + `process.env`).
- **Not published.** `private: true`; the `@h82/` scope is a naming namespace,
  not a registry target. Not installed by the dotfiles bootstrap.

## Install / build / test

This package is a member of the `@h82/dotfiles` Yarn workspace rooted at
[`../`](../) (see [`../README.md`](../README.md)). Install once from the
workspace root; build/test either from the workspace root via a selector or from
this directory.

```sh
# from the workspace root (packages/)
yarn install --immutable                 # restore deps (single root yarn.lock)
yarn workspace @h82/mxm4-haptic build     # tsdown -> dist/index.js (ESM) + dist/index.d.ts
yarn workspace @h82/mxm4-haptic typecheck # tsc --noEmit
yarn workspace @h82/mxm4-haptic test      # node --test (also runnable via `bun test`)
yarn workspace @h82/mxm4-haptic lint      # eslint .
yarn workspace @h82/mxm4-haptic format    # prettier --write .

# or from this directory (packages/mxm4-haptic/)
yarn build && yarn test
yarn lint && yarn format:check
```

The package is ESM-only (`"type": "module"`) and builds with
[`tsdown`](https://tsdown.dev) (Rolldown-based), configured in
[`tsdown.config.ts`](tsdown.config.ts), emitting `dist/index.js` + bundled
`dist/index.d.ts`. Type-checking is a separate `tsc --noEmit` pass.

Linting is ESLint ([`eslint.config.mjs`](eslint.config.mjs):
`@eslint/js` + `typescript-eslint` recommended) and formatting is Prettier
([`.prettierrc.json`](.prettierrc.json), `printWidth: 100`, `semi: true`), with
`eslint-config-prettier` keeping the two from disagreeing on style. See
[`../README.md`](../README.md#lint--format) for the workspace-wide convention.

## Usage

```ts
import { sendCommand, WAVEFORMS, type WaveformName } from "@h82/mxm4-haptic";

// Fire a pulse. ALWAYS await — see the warning below.
// `sendCommand` only accepts a `WaveformName`, so typos are a compile error.
await sendCommand("SHARP COLLISION");

const wave: WaveformName = "COMPLETED";
await sendCommand(wave);

WAVEFORMS; // -> readonly [["SHARP STATE CHANGE", 0], ..., ["WHISPER COLLISION", 27]]
```

### ⚠️ Always `await sendCommand`

`sendCommand` resolves **only after the bytes have flushed** to the daemon (on
the socket's clean `close`). Node buffers writes, so a fire-and-forget caller
that does `sendCommand(...)` and then exits the process **without awaiting** may
drop the pulse. The Rust client got away with fire-and-forget because dropping a
`UnixStream` flushes synchronously; in Node you must await.

## API

| Export | Signature | Notes |
|---|---|---|
| `WAVEFORMS` | `readonly [readonly [name, id], ...]` | The available waveforms: 16 `[name, id]` tuples in firmware order. Source of truth for `WaveformName`. |
| `WaveformName` | `type` | Union of the 16 literal waveform names, derived from `WAVEFORMS`. |
| `sendCommand(name)` | `(name: WaveformName) => Promise<void>` | Type-safe entry point. Validates, connects, writes `NAME\n`, resolves on flush. |

The lookup helpers (`waveformNames`, `waveformId`) and `socketPath` are
**internal** — they are no longer exported. Enumerate the catalogue via
`WAVEFORMS` and let the `WaveformName` type guard call sites instead.

### Errors

All thrown/rejected errors extend `HapticError` (which carries a discriminant
`code`):

| Class | `code` | When |
|---|---|---|
| `UnknownWaveformError` | `UNKNOWN_WAVEFORM` | Name not in the table (thrown **before** connecting) |
| `SocketMissingError` | `SOCKET_MISSING` | No socket at the path (daemon not running) — `ENOENT` |
| `ConnectionRefusedError` | `CONNECTION_REFUSED` | Socket exists but refused — `ECONNREFUSED` |
| `HapticTimeoutError` | `TIMEOUT` | Connect+write exceeded ~500ms |

## Waveforms

The waveform id table is mirrored from the Rust crate. Note the **firmware enum
gap**: ids are contiguous `0..14` for the first 15 waveforms, then
`WHISPER COLLISION = 27` (not 15). A `node:test` drift-guard
([`test/drift-guard.test.ts`](test/drift-guard.test.ts)) parses the Rust
`WAVEFORMS` table and asserts byte-for-byte parity, so the two tables cannot
silently drift.

| Theme | Names |
|---|---|
| State / collision | `SHARP STATE CHANGE`, `DAMP STATE CHANGE`, `SHARP COLLISION`, `DAMP COLLISION`, `SUBTLE COLLISION`, `WHISPER COLLISION` |
| Alerts | `HAPPY ALERT`, `ANGRY ALERT`, `COMPLETED`, `MAD` |
| Rhythmic | `SQUARE`, `WAVE`, `FIREWORK`, `KNOCK`, `JINGLE`, `RINGING` |

See the root [`AGENTS.md`](../../AGENTS.md) "Solaar haptic playback (MX Master
4)" section for the full daemon architecture and HID++ details.
