---
title: Headless Logitech Manager - Plan
type: feat
date: 2026-09-06
topic: logictl-headless-logitech-manager
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective:** Operators can monitor Logitech wireless device battery status with native KDE desktop tray integration and trigger low-latency MX Master 4 haptics from a lightweight headless service without background GUI bloat.
- **Means:** Consolidate `crates/mxm4-haptic` into a unified Rust workspace binary suite (`logictl`/`logid`) with an SNI tray poller and HID++ 2.0 battery reader.
- **Product Authority:** Owns `crates/` and `packages/` CLI tooling for Logitech device interactions. Does not manage kernel drivers, Bluetooth stacks, button remapping, or SmartShift sensitivity.
- **Open Blockers:** None.

---

## Product Contract

### Summary

Replace bloated background managers (Solaar, OpenLogi) with a lightweight, headless Logitech daemon (`logid`) and CLI (`logictl`). The tool preserves sub-millisecond MX Master 4 haptic playback, polls battery level via HID++ 2.0, displays device status in the KDE Plasma System Tray via StatusNotifierItem (SNI), and issues desktop notifications on low battery.

### Problem Frame

Logitech's official options and community tools (Solaar, OpenLogi) impose excessive overhead for users who only need haptic triggering and battery status. Solaar requires heavy Python runtimes, GTK/Qt dependencies, and complex configuration interfaces. OpenLogi adds Electron or WebKit UI baggage and aggressive background polling.

On Linux kernels up to 7.1, the Logitech Bolt receiver (`046d:c548`) exposes HID++ on raw USB hidraw endpoints without generating sysfs `power_supply` nodes for paired devices. UPower daemon relies strictly on kernel `power_supply` or BlueZ D-Bus objects and rejects userspace device injection. Consequently, native desktop battery monitoring requires a lightweight user-session daemon that talks HID++ directly and publishes status via standard desktop protocols.

### Key Decisions

- **Single daemon architecture with unified device ownership**: Single `logid` service owns Bolt receiver interface 2 `/dev/hidraw` to eliminate device access contention and HID++ packet race conditions between haptic commands and battery queries. `(session-settled: user-approved — chosen over separate haptic and battery poller processes: prevents /dev/hidraw device contention and response packet race conditions over Bolt receiver interface 2)` Governs R1, R2, R4.
- **Native StatusNotifierItem (SNI) integration for KDE Plasma**: Expose battery status via session D-Bus SNI and desktop notifications rather than kernel power_supply sysfs or UPower injection. `(session-settled: user-directed — chosen over native KDE UPower panel integration, custom Plasmoid, Bluetooth transition, and DKMS kernel driver: Bolt receiver lacks kernel power_supply and UPower does not support userspace injection, while SNI runs reliably in user session without root)` Governs R5, R6.
- **General-purpose suite naming with backwards-compatible aliases**: Rename tool suite from `mxm4-haptic` to `logictl` / `logid` while preserving `mxm4-haptic` CLI symlinks and TypeScript client compatibility. `(session-settled: user-directed — chosen over keeping mxm4-haptic name: generalizes the tool for future Logitech devices while keeping backwards-compatible symlinks/aliases for existing haptic callers)` Governs R7, R8, R9.
- **Zero-GUI lean scope with deferred peripheral configuration**: Restrict initial release to low-latency haptic playback and battery monitoring, explicitly excluding button remapping, gestures, SmartShift ratchet sensitivity, and DPI tuning. `(session-settled: user-directed — chosen over full feature parity with Solaar/OpenLogi: eliminates bloat and focuses exclusively on essential MX Master 4 haptic playback and battery monitoring)` Governs R3, R10.

<!-- ce-section: work-relationships -->
### How This Work Fits Together

This plan owns the core headless manager and desktop battery reporting.

- `logictl` and `logid` replace `crates/mxm4-haptic`.
- Depends on existing udev rules granting user access to `/dev/hidraw*` endpoints.
- Enables desktop tray battery visibility for Logitech Bolt devices in KDE Plasma 6.
- Shares client protocol with `packages/mxm4-haptic` TypeScript client bindings.
- Can proceed independently of future button remapping or SmartShift configuration features.

### Requirements

#### Device Protocol & Daemon Core

- R1. `logid` daemon maintains exclusive access to the Logitech Bolt receiver HID++ interface (`/dev/hidraw*`) on USB interface 2 (`046d:c548`).
- R2. `logid` listens on a local UNIX domain socket (`$XDG_RUNTIME_DIR/logid.sock`) for client IPC requests.
- R3. `logid` retains sub-millisecond dispatch for MX Master 4 haptic waveform playback over the existing HID++ 0x19 haptic feature.
- R4. `logid` queries connected Logitech devices for battery state and percentage using HID++ 2.0 Feature 0x1000 (`BATTERY_LEVEL_STATUS`) or 0x1004 (`UNIFIED_BATTERY`).

#### Desktop Integration & Notifications

- R5. `logid` exports a StatusNotifierItem (`org.kde.StatusNotifierItem-logid`) on session D-Bus with device battery icon and percentage tooltip.
- R6. `logid` issues an `org.freedesktop.Notifications` desktop notification when device battery level falls below 15% and device is discharging.

#### Client CLI & Compatibility

- R7. `logictl` CLI provides commands to query battery status (`logictl battery`), trigger haptics (`logictl haptic <waveform>`), and inspect connected devices (`logictl status`).
- R8. `mxm4-haptic` binary and symlinks route to `logictl` maintaining full CLI flag and positional argument compatibility for existing callers.
- R9. `@h82/mxm4-haptic` TypeScript client in `packages/mxm4-haptic` interacts seamlessly with the `logid` socket without breaking consumer APIs.

#### Resource Usage & Reliability

- R10. Background idle CPU consumption of `logid` remains under 0.1% with memory footprint below 15MB RSS.

### Key Flows

- F1. Low-latency haptic playback
  - **Trigger:** External application invokes `logictl haptic <waveform>` or sends an IPC command via UNIX socket.
  - **Actors:** Client CLI / TS Client, `logid` daemon, Bolt receiver, MX Master 4 mouse.
  - **Steps:** Client writes command to `$XDG_RUNTIME_DIR/logid.sock`; `logid` reads command, formats HID++ 0x19 packet, and writes directly to open `/dev/hidraw` handle; mouse plays physical vibration.
  - **Outcome:** Haptic feedback fires with sub-millisecond daemon processing latency.
  - **Covers:** R1, R2, R3, R8.

- F2. Periodic battery polling and tray update
  - **Trigger:** Periodic polling timer fires in `logid` (default: 5 minutes) or device wakeup event arrives.
  - **Actors:** `logid` daemon, Bolt receiver, KDE Plasma System Tray (via StatusNotifierWatcher).
  - **Steps:** `logid` sends HID++ 2.0 Feature 0x1000 / 0x1004 query; receiver returns battery percentage and charging state; `logid` updates internal device cache; `logid` emits `NewTitle`, `NewIcon`, or `NewToolTip` D-Bus signal to SNI watcher.
  - **Outcome:** KDE Plasma System Tray updates mouse battery icon and tooltip without waking GUI frameworks.
  - **Covers:** R1, R4, R5.

- F3. Low battery desktop alert
  - **Trigger:** Battery poll detects charge level dropping below 15% while discharging.
  - **Actors:** `logid` daemon, Desktop Notification Server (`org.freedesktop.Notifications`).
  - **Steps:** `logid` checks notification suppression cooldown (minimum 30 minutes between alerts); sends `Notify` D-Bus call with low battery warning and current charge percentage.
  - **Outcome:** User receives desktop notification prompt to plug in device.
  - **Covers:** R4, R6.

### Acceptance Examples

- AE1. Haptic trigger via compatibility wrapper
  - **Given:** `logid` daemon running and MX Master 4 connected.
  - **When:** Caller executes `mxm4-haptic single-strong-click`.
  - **Then:** Wrapper routes to `logictl haptic single-strong-click`, command exits 0, and mouse vibrates.
  - **Covers:** R3, R8.

- AE2. Low battery notification threshold
  - **Given:** Connected mouse reports 14% remaining battery and discharging state.
  - **When:** Polling cycle completes.
  - **Then:** Desktop notification displays with urgency Critical/Normal warning that MX Master 4 battery is low.
  - **Covers:** R4, R6.

- AE3. System tray status and tooltip
  - **Given:** `logid` registered as StatusNotifierItem in active KDE Plasma session.
  - **When:** User hovers cursor over mouse tray icon.
  - **Then:** Tooltip displays "Logitech MX Master 4: 85% (Discharging)".
  - **Covers:** R5, R7.

- AE4. Multiple concurrent haptic commands during battery poll
  - **Given:** Battery poll request packet is awaiting HID++ response.
  - **When:** Haptic command arrives over UNIX domain socket.
  - **Then:** `logid` processes haptic packet with priority without dropping response or corrupting HID++ transaction IDs.
  - **Covers:** R1, R2, R3, R4.

### Scope Boundaries

#### Deferred for later

- SmartShift ratchet sensitivity and toggle mode configuration.
- Custom button remapping and gesture recognition.
- Optical sensor DPI switching and polling rate adjustments.
- Multi-host easy-switch triggering from software.

#### Outside this product's identity

- Heavy desktop graphical configuration windows or settings GUIs.
- Custom KDE Plasmoid development requiring QML/C++ plugins.
- Kernel driver modifications or DKMS modules.
- Non-Logitech hardware management.

### Dependencies / Assumptions

- Host runs Linux kernel with `/dev/hidraw*` accessible to current user (via existing system udev rules).
- Logitech Bolt wireless receiver (`046d:c548`) is plugged in and recognized.
- Active systemd user session running KDE Plasma 6 with session D-Bus accessible at `$DBUS_SESSION_BUS_ADDRESS`.
- Rust toolchain (stable) available to compile `crates/mxm4-haptic` (workspace binary suite).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Rust binary suite consolidation within `crates/mxm4-haptic`**: Build `logid` (daemon), `logictl` (CLI), `mxm4-haptic` (wrapper), and `mxm4-haptic-notify` (preserved notification bridge) from a single Cargo package with shared internal modules. Preserves existing build configurations and path references. Governs R7, R8.
- KTD2. **HID++ 2.0 Feature 0x1000 and 0x1004 battery query protocol**: Probe device feature table for Feature 0x1000 (`BATTERY_LEVEL_STATUS`, function 0 = `getBatteryLevelStatus` returning level %, nextLevel %, batteryStatus 0=discharging/1=recharging/2=almost_full/3=full) or Feature 0x1004 (`UNIFIED_BATTERY`). Cache feature indices per connected slot on discovery and spontaneous 0x41 reconnects. Governs R1, R4.
- KTD3. **zbus-based D-Bus StatusNotifierItem and Desktop Notification dispatch**: Use asynchronous `zbus` in a dedicated background thread within `logid` to register `org.kde.StatusNotifierItem-logid` at `/StatusNotifierItem` on session bus and register with `org.kde.StatusNotifierWatcher`. Call `org.freedesktop.Notifications.Notify` when battery drops below 15% and discharging. Governs R5, R6.
- KTD4. **UNIX domain socket IPC protocol**: Maintain compatibility with existing line-delimited ASCII protocol (`<WAVEFORM>\n` triggers haptic) while supporting dual socket paths (`logid.sock` symlinked from `mxm4-haptic.sock`) and command verbs (`HAPTIC <waveform>`, `BATTERY`, `STATUS`). Governs R2, R7, R8, R9.
- KTD5. **Single-threaded I/O loop with asynchronous IPC & D-Bus synchronization**: `logid` main thread holds the single `hidapi::HidDevice` handle for Bolt receiver interface 2. MPSC channels bridge between IPC socket listener, D-Bus SNI event loop, and the HID I/O loop. Haptic write packets take priority over polling queries. Governs R1, R3, R4, R10.

### High-Level Technical Design

```mermaid
flowchart TB
  subgraph Clients["Clients & Tools"]
    CLI["logictl CLI (battery / haptic / status)"]
    CompatCLI["mxm4-haptic CLI wrapper"]
    TSClient["@h82/mxm4-haptic TS client"]
    NotifyWatcher["mxm4-haptic-notify watcher"]
  end

  subgraph IPC["IPC Layer ($XDG_RUNTIME_DIR)"]
    Sock["logid.sock (symlink: mxm4-haptic.sock)"]
  end

  subgraph Daemon["logid Daemon"]
    IPCServer["IPC Server (AF_UNIX Acceptor)"]
    DBusTask["zbus Task (SNI + Notifications)"]
    IOLoop["HID I/O Loop (Sole Device Owner)"]
    BatteryCache["Device Battery State Cache"]
  end

  subgraph Desktop["KDE Plasma Desktop"]
    Watcher["StatusNotifierWatcher"]
    Tray["KDE System Tray Icon & Tooltip"]
    NotifServer["org.freedesktop.Notifications"]
  end

  subgraph Hardware["Hardware via USB hidraw"]
    Bolt["Logitech Bolt Receiver (046d:c548 / iface 2)"]
    MX4["Logitech MX Master 4"]
  end

  CLI --> Sock
  CompatCLI --> Sock
  TSClient --> Sock
  NotifyWatcher --> Sock
  Sock --> IPCServer

  IPCServer -->|mpsc commands| IOLoop
  IOLoop -->|update battery| BatteryCache
  BatteryCache -->|refresh signals| DBusTask

  DBusTask -->|RegisterStatusNotifierItem| Watcher
  Watcher --> Tray
  DBusTask -->|Notify (level < 15%)| NotifServer

  IOLoop <-->|HID++ Long 0x11 Play / Query| Bolt
  Bolt <-->|2.4GHz Wireless| MX4
```

### Output Structure

```
crates/mxm4-haptic/
├── Cargo.toml               # Updated dependencies (zbus, futures-util) and [[bin]] definitions
├── src/
│   ├── lib.rs               # Protocol definitions: waveforms, HID++ builders, battery parsers, socket path
│   ├── battery.rs           # HID++ 2.0 Feature 0x1000 / 0x1004 query & response classification
│   ├── sni.rs               # zbus StatusNotifierItem & org.freedesktop.Notifications implementation
│   ├── bin/
│   │   ├── logid.rs         # Daemon: device I/O loop, battery poller, SNI publisher, IPC acceptor
│   │   ├── logictl.rs       # CLI: battery, haptic, status subcommands + usage KDL
│   │   ├── mxm4-haptic.rs   # Backward-compatible thin client wrapper forwarding to logid
│   │   ├── mxm4-hapticd.rs  # Backward-compatible alias / symlink entrypoint for logid
│   │   └── mxm4-haptic-notify.rs # Desktop notification -> haptic bridge
packages/mxm4-haptic/
├── src/index.ts             # TypeScript client supporting both legacy socket and new queries
└── test/                    # Parity and sendCommand tests
```

---

## Implementation Units

### U1. HID++ 2.0 Battery Protocol & Feature Discovery

- **Goal:** Implement HID++ Feature 0x1000 (`BATTERY_LEVEL_STATUS`) and 0x1004 (`UNIFIED_BATTERY`) packet builders and reply parsers in the shared library.
- **Requirements:** R1, R4.
- **Dependencies:** None.
- **Files:** `crates/mxm4-haptic/src/lib.rs`, `crates/mxm4-haptic/src/battery.rs`.
- **Approach:**
  1. Define Feature IDs `FEATURE_BATTERY_LEVEL_STATUS` (`0x1000`) and `FEATURE_UNIFIED_BATTERY` (`0x1004`).
  2. Implement `build_get_battery_status(dev_idx, feature_idx, sw_id)` generating the HID++ 2.0 function 0 call.
  3. Implement `BatteryStatus` struct holding `percentage: u8`, `charging: bool`, and `critical: bool`.
  4. Implement `parse_battery_reply(buf, dev_idx, feature_idx, sw_id)` decoding the payload according to Logitech HID++ 2.0 specification.
- **Patterns to follow:** Mirror `build_get_feature` and `classify_root_reply` patterns in `crates/mxm4-haptic/src/lib.rs`.
- **Test scenarios:**
  - Unit test for `build_get_battery_status` packet length, report ID `0x10`, and byte alignment.
  - Unit test parsing 0x1000 response: discharging 50% (`charging = false`), charging 80% (`charging = true`), full 100%.
  - Unit test parsing 0x1004 unified battery response.
  - Unit test verifying non-matching reports return `None` or error without panicking.
- **Verification:** `cargo test` executes and passes all battery builder and parser tests.

### U2. IPC Protocol Extension & Dual Compatibility

- **Goal:** Extend AF_UNIX socket IPC protocol to support battery and status queries while preserving legacy line-delimited waveform commands.
- **Requirements:** R2, R7, R8, R9.
- **Dependencies:** U1.
- **Files:** `crates/mxm4-haptic/src/lib.rs`, `packages/mxm4-haptic/src/index.ts`.
- **Approach:**
  1. In `socket_path()`, resolve `logid.sock` as primary and ensure symlink or fallback to `mxm4-haptic.sock`.
  2. Define `IpcCommand` enum: `PlayWaveform(String)`, `GetBattery`, `GetStatus`.
  3. Update `IpcServer` parser: if input line is recognized as a waveform name, parse as `PlayWaveform`; if line starts with `BATTERY` or `STATUS`, parse as query command.
  4. For queries, write formatted response string back to the connected `UnixStream` before closing.
  5. In `packages/mxm4-haptic/src/index.ts`, support `getBatteryStatus()` while keeping `sendCommand()` unchanged.
- **Patterns to follow:** `ipc_server::IpcServer` in `crates/mxm4-haptic/src/lib.rs`.
- **Test scenarios:**
  - Covers AE1: Legacy waveform string (`COMPLETED\n`) handled as haptic without error.
  - Command verb `BATTERY\n` parsed into `IpcCommand::GetBattery`.
  - Unknown command returns error string without terminating daemon.
  - TypeScript client test: `sendCommand("COMPLETED")` flushes successfully without regression.
- **Verification:** `cargo test` and `bun test --cwd packages/mxm4-haptic` pass.

### U3. `logid` Daemon Core, Battery Polling & Priority I/O Loop

- **Goal:** Upgrade daemon loop to manage battery feature index discovery, periodic polling (5 min interval), device reconnect caching, and priority haptic packet dispatch.
- **Requirements:** R1, R3, R4, R10.
- **Dependencies:** U1, U2.
- **Files:** `crates/mxm4-haptic/src/bin/logid.rs`, `crates/mxm4-haptic/src/bin/mxm4-hapticd.rs`.
- **Approach:**
  1. Rename or alias `mxm4-hapticd.rs` logic into `logid.rs`.
  2. Maintain `DeviceState` struct tracking slot index, haptic feature index, battery feature index, last battery level, and charging state.
  3. During `discover()`, probe both HAPTIC (`0x19B0`) and BATTERY (`0x1000` / `0x1004`).
  4. In `io_loop()`, track `last_battery_poll: Instant`. When elapsed > 5 minutes, send battery status request.
  5. Process incoming IPC play commands with higher priority than battery queries to guarantee sub-millisecond haptic latency.
- **Patterns to follow:** `io_loop` and `handle_play` pacing/debounce logic in `crates/mxm4-haptic/src/bin/mxm4-hapticd.rs`.
- **Test scenarios:**
  - Covers AE4: Concurrent haptic command during pending battery query takes immediate priority.
  - Battery polling updates cached state without blocking read loop.
  - Disconnection notification (0x41 link lost) invalidates target cache cleanly.
  - Idle CPU usage remains under 0.1% with memory RSS under 15MB.
- **Verification:** `cargo test` passes; compiled `logid` runs and responds to synthetic socket events.

### U4. D-Bus StatusNotifierItem (SNI) & Desktop Notifications Integration

- **Goal:** Integrate `zbus` into `logid` to register StatusNotifierItem on session bus and send low-battery desktop notifications.
- **Requirements:** R5, R6.
- **Dependencies:** U3.
- **Files:** `crates/mxm4-haptic/Cargo.toml`, `crates/mxm4-haptic/src/sni.rs`, `crates/mxm4-haptic/src/bin/logid.rs`.
- **Approach:**
  1. Add `zbus = { version = "4", default-features = false, features = ["p2p"] }` to `Cargo.toml`.
  2. Define `StatusNotifierItem` D-Bus interface exposing `Category = "Hardware"`, `Id = "logid"`, `Title = "Logitech Device"`, `Status = "Active"`, `IconName`, and `ToolTip`.
  3. Spawn an async executor thread for `zbus` connection to session bus; register with `org.kde.StatusNotifierWatcher`.
  4. Map battery level to standard freedesktop icon names (`battery-000-symbolic`, `battery-020-symbolic`, `battery-080-symbolic`, `battery-charging-symbolic`).
  5. Check threshold: when level < 15% and discharging, call `org.freedesktop.Notifications.Notify` with 30-minute cooldown.
- **Patterns to follow:** Freedesktop StatusNotifierItem and Desktop Notification specifications.
- **Test scenarios:**
  - Covers AE2: Battery drop below 15% triggers notification call with Critical/Normal urgency.
  - Notification cooldown prevents duplicate alerts within 30 minutes.
  - Covers AE3: SNI tooltip and icon reflect battery percentage and charging state.
  - Disconnected device sets SNI status to `Passive`.
- **Verification:** `cargo test` passes SNI state mapping and notification threshold tests.

### U5. `logictl` Unified CLI & Backward-Compatible Wrappers

- **Goal:** Implement `logictl` CLI with subcommands (`battery`, `haptic`, `status`) and ensure `mxm4-haptic` binary / symlinks maintain full backward compatibility.
- **Requirements:** R7, R8.
- **Dependencies:** U2, U3.
- **Files:** `crates/mxm4-haptic/src/bin/logictl.rs`, `crates/mxm4-haptic/src/bin/mxm4-haptic.rs`, `crates/mxm4-haptic/Cargo.toml`.
- **Approach:**
  1. Add `[[bin]]` for `logictl` in `Cargo.toml`.
  2. Implement subcommands: `logictl battery` (prints percentage, status, and `--json` flag), `logictl haptic <waveform>` (sends waveform to socket), `logictl status` (prints daemon and device state).
  3. Support `--usage` (usage KDL spec) and `--version` on `logictl`.
  4. Retain `mxm4-haptic` binary forwarding directly to `logictl haptic` or using shared library `send_command`, preserving existing exit codes (0 = success, 1 = daemon missing, 2 = bad waveform).
- **Patterns to follow:** `usage_spec()` and argument matching in `crates/mxm4-haptic/src/bin/mxm4-haptic.rs`.
- **Test scenarios:**
  - Covers AE1: `mxm4-haptic "SHARP COLLISION"` exits 0.
  - `logictl battery` outputs battery percentage and charging status.
  - `logictl battery --json` outputs valid JSON object.
  - `logictl --help` displays usage KDL / help text.
  - Exit codes 0, 1, and 2 match previous CLI behavior.
- **Verification:** `cargo test` passes; manual execution of `logictl` and `mxm4-haptic` binaries.

---

## Verification Contract

### Commands

- Rust unit and integration tests:
  ```bash
  cargo test --manifest-path crates/mxm4-haptic/Cargo.toml
  ```
- TypeScript client package tests:
  ```bash
  bun test --cwd packages/mxm4-haptic
  ```
- Clippy code quality and lint checks:
  ```bash
  cargo clippy --manifest-path crates/mxm4-haptic/Cargo.toml --all-targets -- -D warnings
  ```
- Formatting check:
  ```bash
  cargo fmt --manifest-path crates/mxm4-haptic/Cargo.toml -- --check
  ```
- Memory RSS audit:
  ```bash
  ps -o rss=,comm= -p $(pgrep logid)
  ```

---

## Definition of Done

- All 10 requirements (R1..R10) are implemented across units U1..U5.
- All 4 Acceptance Examples (AE1..AE4) pass verification.
- `logid` registers StatusNotifierItem on session bus with dynamic icon and tooltip.
- Desktop notification fires when battery level drops below 15% while discharging.
- `logictl` CLI supports `battery`, `haptic`, and `status` commands.
- Backward compatibility for `mxm4-haptic` CLI and `@h82/mxm4-haptic` TypeScript client confirmed with green test suites.
- No compiler warnings, no Clippy lints, no abandoned experimental code left in working tree.
