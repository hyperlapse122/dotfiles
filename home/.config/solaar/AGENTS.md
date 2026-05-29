# Solaar Rules — Agent Instructions

Scope: any edit to files under `~/.config/solaar/` (linked from `home/.config/solaar/` in this dotfiles repo). The canonical file is `rules.yaml`; Solaar reads it once at process start.

## Required workflow before editing `rules.yaml`

1. **Read live device state first.** Run `solaar show` and copy the exact button labels from the "Has N reprogrammable keys:" section. Do not guess labels from MX Master family knowledge — firmware varies. The current host reports `Haptic` (not `Haptic Button`, not `Gesture Button`) for the MX Master 4 thumb haptic button; older models do not expose this key at all.
2. **Confirm divertability and diversion state in the same output.** A rule on `[<Label>, pressed]` only fires when that key shows `divertable, reprogrammable` AND its diversion is set to `Diverted` (not `Regular`) in `Key/Button Diversion (saved)`. **In this repo, divert state for tracked devices is owned by [`scripts/linux/config-solaar.sh`](../../scripts/linux/config-solaar.sh)** — it edits `~/.config/solaar/config.yaml` in place (PyYAML via `/usr/bin/python3`, atomic write with `.bak` backup) and restarts Solaar only when something changed. Add a new diverted button by appending to the script's `TARGETS` array (model id, control id from `solaar show` reprogrammable-keys section, state, label); do **not** track `config.yaml` itself (it carries per-physical-device `_serial`/`_unitId`/`_battery` fields). **Do not use `solaar config "<device>" divert-keys <Label> Diverted` from the CLI on Solaar 1.1.19** — it flips the runtime device state (the device starts emitting HID++ notifications immediately) but crashes during persistence with `TypeError: Unable to marshal str as an array, use .encode() to convert to bytes` from `/usr/lib64/python3.14/site-packages/gi/overrides/Gio.py`. Result: `Key/Button Diversion        ` shows `Diverted` but `Key/Button Diversion (saved)` still shows `Regular`, and the next mouse reconnect or Solaar restart reverts it. The GUI path persists correctly but isn't automatable; `config-solaar.sh` is the supported automated path. Track upstream at <https://github.com/pwr-Solaar/Solaar>.
3. **Smoke-test the action outside Solaar before wiring it.** For an `Execute:` rule, run the exact argv from a terminal and confirm the observable effect; for a `KeyPress:` rule, type the equivalent shortcut. If it doesn't work outside Solaar, the rule will not work inside Solaar either.

## Hard rules for `rules.yaml`

- **No `%YAML 1.3` directive.** YAML 1.3 is not a published spec; the YAML language server rejects it and Solaar's PyYAML loader does not require it. Plain documents only.
- **Prefer DBus `Execute:` over `KeyPress:` for desktop-environment actions on Wayland.** `solaar show` prints "rules cannot access modifier keys in Wayland" — modifier-conditional rules are unreliable, and synthesized modifier chords via `/dev/uinput` race with real held modifiers. Calling KWin / GNOME Shell / etc. over their DBus interface bypasses keymap, layout, and modifier state entirely.
- **`Execute:` MUST use the YAML list form, not the string form.** List form goes through `subprocess.Popen` with `shell=False`: no shell parsing, no quoting bugs, no injection surface. String form goes through `shell=True` and is forbidden here.
  - ✅ `- Execute: [qdbus-qt6, org.kde.KWin, /Effects, org.kde.kwin.Effects.toggleEffect, overview]`
  - ❌ `- Execute: "qdbus-qt6 org.kde.KWin /Effects org.kde.kwin.Effects.toggleEffect overview"`
- **Use full, verified binary names — never bare `qdbus`.** On Fedora the Qt 6 binary is `qdbus-qt6`; on other distros it is `qdbus6` or `qdbus`. Hard-code the name verified via `command -v` on this host and note it in a comment next to the rule. Do not paper over portability with `bash -c` or a shell wrapper unless the rule explicitly needs to run on multiple distros.
- **Document host-verified facts in a comment above each rule.** At minimum: which `solaar show` label the rule keys on, which Plasma/GNOME/etc. version was verified, and the absolute path of any external binary the rule spawns. These cannot be inferred from the YAML and silently break across firmware updates and distro hops.
- **Do not modify `rules.yaml` to "fix" behavior that the firmware default already produces correctly.** If a button works as desired without diversion, leave its diversion at `Regular` and add no rule. Every diverted button costs a HID++ round-trip per press.
- **Scope a rule with `Device:` when its key label is shared across paired devices.** Button labels are not unique: both the MX Master 4 and MX Master 3S expose `Mouse Gesture Button`. A bare `Key: [Mouse Gesture Button, ...]` rule fires for whichever device sends the notification. Lead such a rule with `- Device: <name>` (matches `device.name`/`codename`/`serial`/`unitId`) so it only acts on the intended mouse. Labels that are unique to one model (e.g. `Haptic`, only on the MX Master 4) don't need the guard. When two devices run the same stateful (tap-vs-hold) pattern concurrently, give each its **own marker file** (e.g. `/tmp/solaar-haptic-held` vs `/tmp/solaar-mgesture-held`) so an in-flight hold on one mouse can't be misread by the other's release rule.

## DBus targets verified on this host (Plasma 6.6.5, Wayland)

Probe with `qdbus-qt6 <service> <path>` before using; the surface changes between Plasma minors.

| Effect | Service | Path | Method | Arguments |
|---|---|---|---|---|
| Activate Overview (and any other KWin effect bound to a shortcut) | `org.kde.kglobalaccel` | `/component/kwin` | `org.kde.kglobalaccel.Component.invokeShortcut` | shortcut name (e.g. `Overview`, `Grid View`, `Cycle Overview`) |

`org.kde.kwin.Effects.toggleEffect` looks like an activation API but is **not** — it toggles the effect plugin's *load state* (equivalent to checking/unchecking the effect in System Settings → Window Management → Desktop Effects), not its runtime activation. Verified by inspection of `qdbus-qt6 org.kde.KWin /Effects`: the only state-changing methods are `loadEffect` / `unloadEffect` / `toggleEffect` / `reconfigureEffect`, all plugin-lifecycle. There is no `activate*` / `run*` / `show*` method on `/Effects`. The canonical runtime activation path is `kglobalaccel` invocation by shortcut name; the shortcut name is stable across rebinds (only KWin upstream renaming the shortcut would break a rule). Do not reach for `toggleEffect` thinking it bypasses keybindings — invoking it twice will *unload the effect plugin*, leaving Overview unreachable until Solaar / KWin is restarted or the plugin is re-enabled.

### No native non-toggle for Overview — gate on `activeEffects` instead

The `Overview` global shortcut **toggles**; Plasma 6.6.5 exposes no explicit show/hide for it. Verified: the overview effect registers **no** dedicated DBus object (unlike `WindowView1`, which has `org.kde.KWin.Effect.WindowView1.activate(QStringList)`), and `shortcutNames` lists only toggles (`Overview`, `Cycle Overview`, `Cycle Overview Opposite`, `Grid View`). To get a deterministic open or close, gate the toggle on live state read from `Effects.activeEffects` (its list contains `overview` iff Overview is on screen):

```bash
# ensure OPEN (idempotent — opens if closed, no-op if already open)
qdbus-qt6 org.kde.KWin /Effects org.kde.kwin.Effects.activeEffects | grep -qx overview \
  || qdbus-qt6 org.kde.kglobalaccel /component/kwin invokeShortcut Overview
# ensure CLOSE (idempotent — closes if open, no-op if already closed)
qdbus-qt6 org.kde.KWin /Effects org.kde.kwin.Effects.activeEffects | grep -qx overview \
  && qdbus-qt6 org.kde.kglobalaccel /component/kwin invokeShortcut Overview || true
```

`activeEffects` lags ~0.5-1s during the open/close animation, so this is reliable only at human-paced intervals (fine for button hold/release; not for tight loops). `grep -qx` matches the whole line because qdbus prints the effect list one entry per line.

### Silent-failure trap: `invokeShortcut` on an unloaded effect

When the target effect's plugin is **unloaded**, `qdbus-qt6 invokeShortcut <name>` exits 0 with no stderr, KGlobalAccel dispatches the shortcut to KWin, KWin has no handler registered, and the call silently no-ops. From the rule's side this looks identical to success: `Execute` logs the action, `subprocess.Popen` returns immediately, and nothing visible happens.

Diagnose with these three probes:

```bash
# Is the effect plugin loaded?
qdbus-qt6 org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded overview
# When invokeShortcut is dispatched, does the effect actually become active?
qdbus-qt6 org.kde.kglobalaccel /component/kwin invokeShortcut Overview
qdbus-qt6 org.kde.KWin /Effects org.kde.kwin.Effects.activeEffects
```

If `isEffectLoaded` returns `false`, recover by re-enabling the effect in **System Settings → Window Management → Desktop Effects** (or one-shot `qdbus-qt6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect <name>`).

How effects get into an unloaded state: System Settings → Window Management → Desktop Effects checkbox toggled off; `kwriteconfig6` writes to `~/.config/kwinrc [Plugins]` followed by KWin reconfigure; stray `org.kde.kwin.Effects.toggleEffect <name>` calls (which is what triggered this trap during initial development of the Haptic rule — empirical balanced toggling was overrun by a parallel KWin reconfigure).

**Do NOT prefix rules with a per-press `loadEffect`.** An earlier version did exactly that as a defensive self-heal; it was removed. The Overview effect is enabled by default and stays loaded in normal use — the only times it unloaded were stray `toggleEffect` calls during development. Worse, a per-press `loadEffect` does not actually fix the rule: the idempotent state-gating above reads `activeEffects`, which never reports `overview` while the plugin is unloaded, so the gate keeps firing a no-op `invokeShortcut` regardless. The correct fix for a genuinely-disabled effect is to re-enable it in System Settings, not to paper over it per press. The current Haptic / Mouse Gesture Button rules in [`rules.yaml`](rules.yaml) use the idempotent ensure-OPEN / ensure-CLOSE pattern and no `loadEffect`.

## Reloading after edits

Solaar does not watch `rules.yaml`. After editing, restart the process to load the new rule set:

```bash
systemctl --user restart app-solaar@autostart.service
```

(Solaar is autostarted via the systemd-generated unit from its XDG `.desktop` file; this is the supported reload path.) The GUI Rule Editor's "Load" button is an alternative when iterating, but the **Save** button writes the editor's in-memory state back to disk and will overwrite manual edits if you forget to Load first.

## Verification gate before declaring an edit done

1. `solaar show 2>&1 | grep -iE 'failed|error|rules.yaml'` returns no rows.
2. The Solaar process is the freshly restarted one (`pgrep -af solaar` shows a PID launched after the edit).
3. The mapped button produces the documented effect on a real press — not just "the DBus call works when I run it manually".

## Stateful patterns (tap-vs-hold, double-click, etc.)

Solaar 1.1.19 rules have no rule-local variable system and no way to cancel a scheduled `Later`. Maintainer confirmation: [pwr-Solaar/Solaar#2915](https://github.com/pwr-Solaar/Solaar/issues/2915) — *"a rule runs for a single notification; `Later` only delays evaluation in the same environment."* `Set:` writes real device settings, not scratch state.

For patterns that need state across two events (press → release), the smallest workable carrier is a **filesystem marker** in `/tmp`, driven by:

1. Press rule: clear stale marker (idempotent self-healing against crashes), do the press-time action, schedule a `Later: [<threshold>, KeyIsDown: <Label>, Execute: [touch, /tmp/<marker>]]`. The `KeyIsDown` condition fires at threshold time; if the key was already released (tap path), the touch is suppressed and no marker is created.
2. Release rule: check marker via `bash -c "[ -f /tmp/<marker> ] && rm -f … && <hold-release-action> || true"`. Marker present = hold, marker absent = tap.

`Later` accepts floats `0.01..100` in 1.1.19 code (docs page incorrectly says int `1..100`), so sub-second thresholds like 0.2 are valid.

Marker file location: `/tmp` is acceptable for single-user-Solaar machines (one MX Master 4 Haptic-diverted per session). For multi-user contention or to survive `/tmp` cleanups within session, prefer `${XDG_RUNTIME_DIR}/<marker>`, but rules.yaml's `Execute` does not expand environment variables — either hardcode `/run/user/<uid>` (loses portability across machines) or wrap in `bash -c`.

`bash -c` is allowed for **conditional file-test + chained-command logic** that has no native Solaar primitive (file existence, sub-second timing decisions). It is **not** allowed for portability papering of binary names — those must be host-verified and hard-coded per the "verified binary names" rule above. Keep `bash -c` invocations in list form so argv passes through with `shell=False`.

**Dedicated helper binaries are preferred over inline shell** when:

1. The logic exceeds what a YAML one-liner can express cleanly (multi-step state, parsing, error handling).
2. Solaar's native primitive (`Set`, `KeyPress`, etc.) has a documented failure mode for the use case. E.g. `Set: [null, haptic-play, <wf>]` waits for an HID++ ack (PlayHapticWaveForm doesn't pass `no_reply=True`); Bolt-wireless ack variance (30-300 ms) makes pulses feel inconsistent. The [`mxm4-haptic`](../../.local/bin/mxm4-haptic) helper exists exactly to bypass that — direct hidraw write, no ack wait, ~5-15 ms flat. See the root AGENTS.md "Solaar haptic playback (MX Master 4)" section for the canonical alternatives table.
3. The helper has external state that's expensive to recompute per call (e.g. `mxm4-haptic`'s device/feature index cache, populated once by `scripts/linux/config-solaar.sh`).

Reference implementation: the Haptic tap-vs-hold rules in [`rules.yaml`](rules.yaml). The Later callback chains `Execute: [touch, ...]` (marker) and `Execute: [mxm4-haptic, "<WAVEFORM>"]` (helper) — both within a single `KeyIsDown`-gated sub-rule so neither fires on a tap.

## Out of scope

- `~/.config/solaar/config.yaml` — schema is per-physical-device (`_serial`, `_unitId`, `_battery`, `_absent`). Tracking the file verbatim is rejected; mutate it through [`scripts/linux/config-solaar.sh`](../../scripts/linux/config-solaar.sh) instead.
- `~/.config/solaar/devices/` (per-device persistence; managed by Solaar at runtime).
- System-wide Solaar udev rules (managed by the distro / `system/linux/etc/` in this repo, not here).
