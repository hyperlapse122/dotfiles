# home/Library/LaunchAgents/

macOS **launchd** user agents, applied into `~/Library/LaunchAgents/` by
chezmoi from the `home/Library/LaunchAgents/` source tree.
This is the macOS counterpart of the Linux
[`home/.config/systemd/user/`](../../.config/systemd/user/) `systemd --user`
units — a per-user autostart that needs no root.

## Agents

| Agent | Runs | Purpose |
|---|---|---|
| `dev.h82.mxm4-hapticd.plist` | `~/.local/bin/mxm4-hapticd` | MX Master 4 haptic daemon — sole owner of the Bolt receiver HID++ session; does HID++ device discovery, debounce, queueing and paced playback over `hidapi` (macOS IOKit). Listens on `$TMPDIR/mxm4-haptic.sock`. |

The daemon is built from [`../../../crates/mxm4-haptic/`](../../../crates/mxm4-haptic/)
into `~/.local/bin/` during bootstrap (`install.sh` `cargo install`
step, daemon + client only). There is **no** agent for the notification bridge
(`mxm4-haptic-notify`): it is Linux-only (it eavesdrops the D-Bus session bus)
and exits immediately on macOS. macOS has no Solaar to spawn the one-shot client
`mxm4-haptic` from rules; the natural driver is the AF_UNIX socket — e.g. the
[`@h82/opencode-mxm4-haptic`](../../../packages/opencode-mxm4-haptic/) plugin.

## Loading

The agent is loaded automatically during bootstrap by the guarded `launchctl
bootstrap` step in [`../../../install.sh`](../../../install.sh),
right after the `cargo install` step builds its binary. `RunAtLoad` starts it
immediately and at every login; `KeepAlive` restarts it if it exits (the daemon
exits on a HID read error to force a clean device re-enumeration). The step
soft-skips when there is no GUI session (`gui/$(id -u)` domain unavailable —
SSH / CI / headless runs) — in that case load it manually once logged in:

```sh
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/dev.h82.mxm4-hapticd.plist
```

Verify, and stop/reload:

```sh
launchctl print "gui/$(id -u)/dev.h82.mxm4-hapticd"          # status
launchctl bootout "gui/$(id -u)/dev.h82.mxm4-hapticd"        # stop + unload
```

Re-running the bootstrap is idempotent: it `bootout`s (ignoring "not loaded")
before `bootstrap`, so the agent reloads with the current plist.

## Conventions

- `Label` MUST equal the plist filename without `.plist` (reverse-DNS,
  `dev.h82.<name>`).
- launchd does not expand `~`/`$HOME` in `ProgramArguments` path strings; exec
  through `/bin/sh -c 'exec "$HOME/..."'` so the per-machine home resolves at
  launch.
- Long-running device daemons use `KeepAlive` + `ThrottleInterval` (the macOS
  analogue of the units' `Restart=always` + `RestartSec`).
