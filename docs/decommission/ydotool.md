# ydotool decommission checklist (operator-run, not automated)

> **Label:** ydotool decommission checklist. This document is manual operator
> guidance for hosts that previously applied the managed ydotool runtime.
> Chezmoi executes none of it: the removal is source-only plus a `.chezmoiremove`
> prune, apply never stops a live service, unmasks a unit, or removes a package,
> and no teardown script exists or may be added.

Apply the updated source first, then work through this checklist by hand on each
previously provisioned Fedora KDE/GNOME desktop. Deleting the managed sources
stopped chezmoi from managing the runtime, and `.chezmoiremove` reclaims the two
deployed files, but a running `ydotoold`, the enabled unit's symlink, the masked
root service, and the installed package all survive an apply untouched.

Ordering is not load-bearing: `systemctl --user disable` removes a dangling
`.wants` symlink even after the unit file is gone, and a running service stays
stoppable by name while systemd holds its loaded unit. This checklist uses the
apply-first order the other decommission documents here use.

## 1. Apply the updated source

- Run your normal `chezmoi apply`. It deletes the managed sources and prunes the
  two deployed targets `~/.config/systemd/user/ydotool.service` and
  `~/.local/libexec/ydotoold-active-seat`. A missing path is fine.
- Nothing else changes: the daemon keeps running until step 2, and no service,
  mask, or package is touched.

## 2. Stop the user unit

- `systemctl --user stop ydotool.service`
- This is what releases the device. The unit's `ExecStart` process is the
  active-seat wrapper, not `ydotoold` directly, and its `EXIT`/`INT`/`TERM` trap
  unlinks `$XDG_RUNTIME_DIR/.ydotool_socket` and then terminates its `ydotoold`
  child. A running wrapper keeps its open inode after the prune deleted the file,
  so the cleanup still works. The socket needs no step of its own.

## 3. Disable the user unit

- `systemctl --user disable ydotool.service`
- **Expect a non-zero exit and `Unit ydotool.service does not exist`.** The unit
  file is already gone; systemd still removes the
  `graphical-session.target.wants/ydotool.service` symlink, which is the point of
  this step. Do not treat the exit status as failure.
- `systemctl --user daemon-reload`
- If a graphical login happened between step 1 and this step, the journal may
  hold one failed start for a unit that no longer exists. It is cosmetic and
  stops recurring once the symlink is gone.

## 4. Verify /dev/uinput is released

- Confirm no `ydotoold` process survives — for example `pgrep -a ydotoold`, and
  `fuser -v /dev/uinput` or `lsof /dev/uinput` to see who still holds the node.
- If a `ydotoold` survives, terminate that process directly (`kill` its PID, then
  `kill -9` only if it ignores `SIGTERM`). Never kill a process you cannot
  attribute to this stack — Solaar legitimately opens `/dev/uinput` too, and
  killing it breaks the MX Master gestures.

## 5. Unmask the packaged root service

- `sudo systemctl unmask ydotool.service`
- The Fedora installer used to mask this unit so the package's root daemon could
  not race the per-user runtime. The mask is a
  `/etc/systemd/system/ydotool.service -> /dev/null` symlink that survives both
  the source removal and the package removal, so clear it before step 6.

## 6. Remove the package

- `sudo dnf remove ydotool`
- The package manifest has no removal key and this repository adds no teardown
  scripts, so package removal is a one-time manual step — the same convention the
  `kitty` note in `.chezmoidata/packages.yaml` documents.

## 7. What stays — do not remove

- `system/linux/etc/udev/rules.d/70-uinput-solaar.rules` and its deployed
  `/etc/udev/rules.d/70-uinput-solaar.rules` **stay**. The active-seat
  `TAG+="uaccess"` grant on `/dev/uinput` belongs to Solaar: its MX Master
  gesture rules synthesize `KeyPress` and `MouseScroll` through evdev uinput
  under Wayland and stop working without it. ydotoold only ever shared the grant.
- `/etc/udev/rules.d/80-uinput.rules`, if a host still carries it, is reclaimed
  automatically by the system installer manifest on the next apply; remove it by
  hand only if the host will not apply again.
