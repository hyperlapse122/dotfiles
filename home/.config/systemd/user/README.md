# home/.config/systemd/user/

`systemd --user` unit files, symlinked into `~/.config/systemd/user/` by
dotbot (the `~/.config/**/*` glob in [`../../../install.linux.yaml`](../../../install.linux.yaml)).

## Units

| Unit | Runs | Purpose |
|---|---|---|
| `mxm4-hapticd.service` | `~/.local/bin/mxm4-hapticd` | MX Master 4 haptic daemon — sole owner of the Bolt receiver HID++ session; does native HID++ device discovery, debounce, queueing and paced playback. Listens on `$XDG_RUNTIME_DIR/mxm4-haptic.sock`. |
| `mxm4-haptic-notify.service` | `~/.local/bin/mxm4-haptic-notify` | Desktop-notification → haptic bridge; eavesdrops `org.freedesktop.Notifications.Notify` via `dbus-monitor` and forwards a waveform to the daemon. |

Both binaries are built from [`../../../crates/mxm4-haptic/`](../../../crates/mxm4-haptic/)
into `~/.local/bin/` during bootstrap (`install.linux.yaml` `cargo install`
step). The Solaar-spawned one-shot client `mxm4-haptic` from the same crate
needs no unit — it is launched per button press by the rules in
[`../../solaar/rules.yaml`](../../solaar/rules.yaml).

## Enabling

dotbot links the unit files but cannot enable them during bootstrap (no
graphical session / user manager bus in an agent or CI run — same
constraint as `scripts/linux/config-solaar.sh`). Enable manually once:

```bash
systemctl --user daemon-reload
systemctl --user enable --now mxm4-hapticd.service mxm4-haptic-notify.service
```

Verify:

```bash
systemctl --user status mxm4-hapticd.service mxm4-haptic-notify.service
```

## Conventions

- One concern per unit; order dependents with `After=`/`Wants=`.
- Units that need the session bus (D-Bus, notifications) bind to
  `graphical-session.target`; device-only units use `default.target`.
- `Restart=always` + `RestartSec=2`: these are long-running daemons that
  must survive bus restarts and transient device disconnects.
