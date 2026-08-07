# ydotool decommission checklist (operator-run, not automated)

> **Label:** ydotool decommission checklist. This document is manual operator
> guidance for hosts that previously applied the managed ydotool runtime.
> Chezmoi executes none of it: the removal is source-only plus a `.chezmoiremove`
> prune, apply never stops a live service, unmasks a unit, or removes a package,
> and no teardown script exists or may be added.

**Ordering IS load-bearing here, unlike the other checklists in this directory.**
Stop and disable the per-user unit **before** the first apply. The apply prunes
`~/.local/libexec/ydotoold-active-seat`, which is the unit's own `ExecStart`
target. Leaving the unit live across that prune risks a restart loop: the
wrapper exits non-zero whenever its supervised `ydotoold` child dies while
`/dev/uinput` is still writable — a screen unlock or fast user switch is enough —
and the unit's `Restart=on-failure` then re-execs a path that no longer exists.
With no `StartLimitBurst` override, systemd's default five-starts-in-ten-seconds
limit is exhausted almost immediately and the unit lands in `failed`
(`Result: start-limit-hit`), with journal noise that does not obviously trace
back to `chezmoi apply`. Recovering from that needs
`systemctl --user reset-failed ydotool.service` on top of the steps below.

Work through this on each previously provisioned Fedora KDE/GNOME desktop.

## 0. Before the first apply: check for a hand-authored unit

`~/.config/systemd/user/ydotool.service` is the path essentially every
third-party ydotool setup guide tells users to hand-author. `.chezmoiremove`
cannot tell a file chezmoi deployed from one you wrote yourself, so on a host
that never applied this repository's ydotool sources, the prune in step 2 would
delete your own file.

- Run `cat ~/.config/systemd/user/ydotool.service`. This repository's version is
  identifiable by `Description=Active-seat ydotoold wrapper` and
  `ExecStart=%h/.local/libexec/ydotoold-active-seat`.
- If it is yours rather than this repository's, back it up before applying, and
  restore it afterwards — or keep it and skip this checklist entirely.

## 1. Stop and disable the user unit

- `systemctl --user stop ydotool.service`
- This is what releases the device. The unit's `ExecStart` process is the
  active-seat wrapper, not `ydotoold` directly, and its `EXIT`/`INT`/`TERM` trap
  unlinks `$XDG_RUNTIME_DIR/.ydotool_socket` and then terminates its `ydotoold`
  child. The socket needs no step of its own.
- `systemctl --user disable ydotool.service`
- `systemctl --user daemon-reload`
- Doing both before the apply keeps the `graphical-session.target.wants` symlink
  resolvable and avoids the restart loop described above. (`disable` does still
  clear a dangling symlink after the unit file is gone — it just exits non-zero
  with `Unit ydotool.service does not exist` — so a host that already applied is
  recoverable; it is simply not the order to choose.)

## 2. Confirm /dev/uinput is released

- Confirm no `ydotoold` process survives — for example `pgrep -a ydotoold`, and
  `fuser -v /dev/uinput` or `lsof /dev/uinput` to see who still holds the node.
- If a `ydotoold` survives, terminate that process directly (`kill` its PID, then
  `kill -9` only if it ignores `SIGTERM`). Never kill a process you cannot
  attribute to this stack — Solaar legitimately opens `/dev/uinput` too, and
  killing it breaks the MX Master gestures.

## 3. Apply the updated source

- Run your normal `chezmoi apply`. It deletes the managed sources and prunes the
  two deployed targets `~/.config/systemd/user/ydotool.service` and
  `~/.local/libexec/ydotoold-active-seat`. A missing path is fine.
- **Verify the prune actually fired:** `ls ~/.config/systemd/user/ydotool.service
  ~/.local/libexec/ydotoold-active-seat` should report both missing. The prune is
  gated on the same host facts that deployed the files, and the `headless` fact
  fails safe to *true* when `~/.cache/chezmoi/facts.yaml` is missing or corrupt —
  so on a first apply, or on a host that became headless since deployment, the
  prune silently does not fire and chezmoi still exits 0. If either file is still
  there, delete it by hand; the leftovers are inert either way.
- `~/.local/libexec/` may be left behind empty. Removing it is optional.

## 4. Remove the package

- `sudo dnf remove ydotool`
- The package manifest has no removal key and this repository adds no teardown
  scripts, so package removal is a one-time manual step — the same convention the
  `kitty` note in `.chezmoidata/packages.yaml` documents.
- Removing the package **before** unmasking is deliberate. Unmasking first would
  leave the root `ydotool.service` startable again — masking never cleared any
  enablement the RPM's install-time preset may have created — reopening exactly
  the root-daemon-races-`/dev/uinput` condition the mask existed to prevent, for
  as long as it takes you to get to this step.

## 5. Clear the leftover mask

- `sudo systemctl unmask ydotool.service`
- `sudo systemctl daemon-reload`
- The Fedora installer used to mask this unit so the package's root daemon could
  not race the per-user runtime. The mask is a
  `/etc/systemd/system/ydotool.service -> /dev/null` symlink that survives both
  the source removal and the package removal. With the package already gone,
  clearing it now closes no window and leaves no orphan.

## 6. What stays — do not remove

- `system/linux/etc/udev/rules.d/70-uinput-solaar.rules` and its deployed
  `/etc/udev/rules.d/70-uinput-solaar.rules` **stay**. The active-seat
  `TAG+="uaccess"` grant on `/dev/uinput` belongs to Solaar: its MX Master
  gesture rules synthesize `KeyPress` and `MouseScroll` through evdev uinput
  under Wayland and stop working without it. ydotoold only ever shared the grant.
- `/etc/udev/rules.d/80-uinput.rules`, if a host still carries it, is reclaimed
  automatically by the system installer manifest on the next apply; remove it by
  hand only if the host will not apply again.

## 7. If you ever reinstall ydotool

This repository will not mask the packaged root `ydotool.service` again. That
protection was removed with the rest of the capability, not preserved elsewhere,
and nothing here installs or manages ydotool any more. An operator who reinstalls
the package — deliberately or as another package's dependency — owns the decision
of whether to mask the root unit by hand.

## 8. Credential boundary — no chezmoi-managed credentials exist

ydotool never had a credential surface: no `op://` reference, no token, no
key material, and no runtime state beyond the mode-0600 socket in
`$XDG_RUNTIME_DIR` that step 1 already removed. There is nothing to rotate,
revoke, or delete in 1Password or anywhere else.
