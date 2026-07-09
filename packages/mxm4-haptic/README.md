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
> binary. This library is for **Node-compatible hosts** (Node, Bun, etc.) as a
> consumer (scripts, tooling, MCP servers, etc.) that wants to trigger haptics
> from a JavaScript runtime.

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

This package is a member of the `@h82/dotfiles` Bun workspace rooted at
[`../`](../) (see [`../README.md`](../README.md)). Install once from the
workspace root; build/test either from the workspace root by changing into the
member directory or from this directory.

```sh
# from the workspace root (packages/)
cd packages
vp install --frozen-lockfile               # restore deps (single root bun.lock)
vp run -r build                            # vp pack across all members
vp run -r typecheck                        # tsc --noEmit
vp run -r test                             # Vitest
vp check                                   # format + lint + type-check (whole workspace)

# or build/test just this member:
cd mxm4-haptic
vp pack && vp test
```

The package is ESM-only (`"type": "module"`) and builds with `vp pack` (tsdown /
Rolldown under the hood), configured in the `pack` block of
[`vite.config.ts`](vite.config.ts), emitting `dist/index.js` + bundled
`dist/index.d.ts`. Type-checking is a separate `tsc --noEmit` pass (`vp run
typecheck`).

Linting is Oxlint and formatting is Oxfmt (`vp lint` / `vp fmt`, or `vp check`
for both plus type-checking), configured once in the workspace-root
[`../vite.config.ts`](../vite.config.ts) `lint` / `fmt` blocks. See
[`../README.md`](../README.md#lint--format--test) for the workspace-wide
convention.

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
`WHISPER COLLISION = 27` (not 15). A Bun drift-guard
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
