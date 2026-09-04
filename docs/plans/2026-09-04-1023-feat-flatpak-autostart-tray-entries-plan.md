---
title: Flatpak Autostart Tray Entries - Plan
type: feat
date: 2026-09-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Flatpak Autostart Tray Entries - Plan

## Goal Capsule

- **Objective**: On a managed Linux workstation, Telegram is already running and reachable from the system tray right after login, without a window stealing focus — the same thing Discord already does.
- **Means**: Add a repo-owned `telegram.desktop` autostart entry that passes `-startintray`, realign `discord.desktop` onto the same minimal `flatpak run` invocation, and gate both entries on `os == linux` and `features.flatpaks` (KTD1, KTD2).
- **Authority Hierarchy**: `.chezmoidata/features.yaml` (feature flags) > `dot_config/autostart/.chezmoiignore` (deployment gate) > `dot_config/autostart/*.desktop` (entry content).
- **Stop Conditions**: Stop and report if a scratch-destination render shows either entry deployed on a target that should be gated out, or if `desktop-file-validate` rejects either file.

---

## Product Contract

### Summary

Telegram gets a repo-managed autostart entry that starts it minimized into the tray. The existing Discord entry moves onto the same invocation form in the same change. Both entries then deploy only on Linux hosts that have Flatpaks enabled.

### Problem Frame

`org.telegram.desktop` is already declared in the Flatpak install list and is installed on this host, but nothing starts it at login, so it is only running when the user remembers to launch it. Discord solves the same problem with `dot_config/autostart/discord.desktop`, but that file was copied verbatim from the Flatpak-exported desktop entry: it pins `--arch=x86_64` and `--branch=stable`, and carries `--command` and `--file-forwarding` arguments that an autostart entry never needs. Telegram publishes an aarch64 build on Flathub, so an entry copied the same way would carry the same architecture pin onto a host where it is wrong. The autostart directory also has no OS or feature gate, so its Flatpak entries deploy to macOS targets and to hosts with `features.flatpaks: false`.

### Key Decisions

- **Repo owns the autostart entry, not Telegram's in-app setting.** Under Flatpak, Telegram's own "launch on login" goes through the XDG background portal and creates a second autostart entry; the two together launch the app twice. The repo entry applies declaratively to every managed host, and the in-app setting stays off. (session-settled: user-approved — chosen over enabling Telegram's own launch-on-login: the in-app setting is per-machine and cannot be declared by chezmoi.) Governs R1, R6.
- **Discord's entry is realigned in this same change.** One invocation form for both Flatpak autostart entries, so the Telegram entry does not inherit the pins by imitation. (session-settled: user-directed — chosen over adding Telegram only and leaving Discord untouched: two Flatpak entries with divergent Exec forms is the state that produced the architecture pin.) Governs R2, R3.
- **Both entries are gated on Linux and on `features.flatpaks`.** (session-settled: user-directed — chosen over an Exec-only cleanup with no gate, and over a Linux-only gate: an autostart entry for an app the host was never asked to install is dead configuration.) Governs R4, R5.

### Requirements

**Telegram autostart**

- R1. Telegram starts at login into the system tray with no visible window.
- R6. The Telegram entry passes no `-autostart` flag and sets no `DBusActivatable` key. Telegram exits immediately when given `-autostart` while its in-app launch-on-login setting is off, and a D-Bus-activated launch bypasses the `Exec` line and loses `-startintray`.

**Shared invocation form**

- R2. Both Flatpak autostart entries invoke `flatpak run` with the application ID and the minimize flag only — no `--arch`, `--branch`, `--command`, `--file-forwarding`, or `%U`/`@@u @@` field codes.
- R3. Discord keeps its current minimized-start behavior through `--start-minimized`.

**Deployment gate**

- R4. Neither entry deploys on a non-Linux target.
- R5. Neither entry deploys when `features.flatpaks` is false.

### Success Criteria

- After a logout and login on this host, Telegram is present in the KDE system tray and no Telegram window is on screen.
- A scratch-destination `chezmoi managed` run lists both entries when the host is Linux with `features.flatpaks: true`, and lists neither when either condition is false.

### Scope Boundaries

- The Flatpak install declaration in `.chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl` is unchanged. `org.telegram.desktop` is already in its `flatpaks=()` array.
- The four native autostart entries (`1password.desktop`, `steam.desktop`, `org.fcitx.Fcitx5.desktop`, `tailscale-systray.desktop`) and `kleopatra.desktop` are unchanged. They are not Flatpak entries and the gate does not apply to them.
- Telegram's own settings — tray icon visibility and launch-on-login — live in the application's binary settings file. chezmoi cannot declare them, so they stay outside management.

#### Deferred to Follow-Up Work

- No `.ci/test-*.sh` case is added for the new gate. The repository's CI tests cover multi-branch render logic and hard-error contracts; a two-condition ignore block over two files does not reach that bar. The render matrix in U3's verification proves it at implementation time instead.
- `app-discord@autostart.service` failed at the logins on 2026-09-01 and 2026-09-04 with `error: Extension org.freedesktop.Platform.GL.default has invalid merge-dirs`, so Discord has not actually been autostarting. The same unit starts cleanly outside login with both the old and the new `Exec` line, and the installed GL extension metadata is well-formed, so this is a login-time Flatpak condition and not an autostart-entry defect. This plan does not address it.
- Flathub publishes no aarch64 build of `com.discordapp.Discord` (`flatpak remote-info --arch=aarch64` returns `Can't find ref`), so the unconditional `flatpak install` in `.chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl` fails on an aarch64 host. That is a pre-existing install-script gap, not an autostart-entry gap, and this plan does not change the install declaration.

### Dependencies

- `org.telegram.desktop` must be installed for the entry to do anything. The existing Flatpak component script already installs it, and this plan does not re-declare it.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Minimal `flatpak run <app-id> <flag>` Exec form.** Four arguments come off. Both application IDs declare a default `command` in their Flatpak metadata that matches what the exported entry passes as `--command=`, so that argument is redundant. `--branch=stable` names the only installed branch. `--file-forwarding` with `@@u %U @@` forwards file arguments an autostart launch never receives. `--arch=x86_64` pins the architecture, which is wrong on an aarch64 host for any application that publishes an aarch64 build. (session-settled: user-directed — chosen over copying the exported desktop entry verbatim: the exported form is built for the applications menu, not for autostart.) Instantiates the Discord-realignment Key Decision; governs R2, R3.
- KTD2. **The gate lives in `dot_config/autostart/.chezmoiignore`, not the root one.** That file already owns per-entry gating for this directory (it gates `kleopatra.desktop` on the `desktop` fact), and its patterns are relative to the autostart directory, so the entries are named as bare filenames. Verified against a scratch source: a nested `.chezmoiignore` listing `b.desktop` excludes exactly that entry, and `.features` resolves inside it with the same `(default dict .features).flatpaks` idiom the root file uses. Governs R4, R5.
- KTD3. **The Telegram entry is written fresh rather than derived from the exported file.** The exported entry carries `DBusActivatable=true`, `SingleMainWindow=true`, `Actions=quit`, `MimeType`, and `X-GNOME-*` keys. `DBusActivatable=true` is the harmful one — a session manager that D-Bus-activates the entry never reads `Exec` and drops `-startintray`. Governs R6.
- KTD4. **Discord's key set is left as-is; only its `Exec` line changes.** The confirmed scope is invocation-form alignment. Rewriting its key set would be a second, unrequested change to a file that works today.

### Assumptions

- Telegram's tray icon is enabled. `-startintray` hides the main window, so with the tray icon off the application would have no reachable surface. Telegram enables it by default where a StatusNotifierItem host exists, and this host's `desktop` fact is `kde`. On a host where the tray icon has been turned off, the entry is still correct but the window is unreachable until it is turned back on.
- Only one branch of each application is installed. Without `--branch`, `flatpak run` resolves the single installed branch; it would need disambiguation only if a beta branch were installed alongside stable.
- The Telegram entry repeats `StartupWMClass` from the Flatpak-exported entry, as the Discord entry already does. Two desktop entries claiming one window class can make a task manager attribute the window to the autostart entry. Discord has carried this without incident, so the plan mirrors it rather than diverging.

### Sources

- `dot_config/autostart/discord.desktop` — the existing Flatpak autostart entry and the pattern being aligned to.
- `dot_config/autostart/.chezmoiignore` — the existing per-entry gate for this directory, gating `kleopatra.desktop` on the `desktop` fact.
- `.chezmoiignore` lines 53-55 — the existing `features.flatpaks` gate idiom, `(default dict $features).flatpaks`.
- `/var/lib/flatpak/exports/share/applications/org.telegram.desktop.desktop` — the exported entry the new file deliberately does not copy.
- `/var/lib/flatpak/app/<app-id>/current/active/metadata` — confirms the default `command` for both applications matches the exported `--command=` value.
- `flatpak remote-info --system flathub <app-id> --arch=aarch64` — Telegram publishes an aarch64 build; Discord does not.
- `AGENTS.md` "Verification (never deploy live `$HOME`)" — the scratch-destination render recipe the Verification Contract uses.
- `man:systemd-xdg-autostart-generator(8)`, and `systemctl --user list-dependencies xdg-desktop-autostart.target` — this host runs Plasma under systemd startup, so autostart entries become units rather than being launched from the desktop file directly.

---

## Implementation Units

### U1. Add the Telegram autostart entry

- **Goal**: Telegram starts at login into the tray.
- **Requirements**: R1, R2, R6
- **Dependencies**: none
- **Files**: `dot_config/autostart/telegram.desktop` (new)
- **Approach**:
  1. Write a plain (non-template) desktop entry, matching the key shape `dot_config/autostart/discord.desktop` already uses.
  2. Set the `Exec` line to `/usr/bin/flatpak run org.telegram.desktop -startintray`.
  3. Include `Type`, `Name`, `Comment`, `GenericName`, `Icon=org.telegram.desktop`, `Terminal=false`, `StartupWMClass=TelegramDesktop`, `Categories`, and `X-Flatpak=org.telegram.desktop`.
  4. Omit `DBusActivatable`, `SingleMainWindow`, `Actions`, `MimeType`, and the `X-GNOME-*` keys per KTD3.
- **Patterns to follow**: `dot_config/autostart/discord.desktop` for the key set and ordering.
- **Test expectation**: none -- a static desktop entry with no branching. Proof is the U1 verification below.
- **Verification**: `desktop-file-validate` accepts the file. A scratch-destination render places it at `.config/autostart/telegram.desktop` with the `Exec` line intact. The Verification Contract's live login check is what proves R1.

### U2. Align the Discord autostart entry's Exec line

- **Goal**: Both Flatpak autostart entries share one invocation form, and Discord's entry stops being architecture-specific.
- **Requirements**: R2, R3
- **Dependencies**: none
- **Files**: `dot_config/autostart/discord.desktop`
- **Approach**: Replace the `Exec` line with `/usr/bin/flatpak run com.discordapp.Discord --start-minimized`. Change nothing else in the file (KTD4).
- **Patterns to follow**: The `Exec` line U1 writes.
- **Test expectation**: none -- a single-line configuration change. Proof is the U2 verification below.
- **Verification**: `git diff` on the file shows one changed line. `desktop-file-validate` accepts the file. `flatpak run com.discordapp.Discord --start-minimized` launches Discord minimized to the tray.

### U3. Gate both Flatpak autostart entries on Linux and `features.flatpaks`

- **Goal**: Neither entry deploys to a target that cannot use it.
- **Requirements**: R4, R5
- **Dependencies**: U1, U2
- **Files**: `dot_config/autostart/.chezmoiignore`
- **Approach**:
  1. Add a second gated block below the existing `kleopatra.desktop` block, listing `discord.desktop` and `telegram.desktop`.
  2. Fire the block when `.chezmoi.os` is not `linux`, or when `features.flatpaks` is false, using the `(default dict .features).flatpaks` idiom from `.chezmoiignore` lines 53-55.
  3. Add a comment stating why the entries are gated, matching the existing file's commenting style.
  4. Leave the existing `$f := includeTemplate "facts.tmpl"` assignment and the `kleopatra.desktop` block untouched — the new block needs no host fact.
- **Patterns to follow**: The `kleopatra.desktop` block in the same file for gate shape and comment style; `.chezmoiignore` lines 53-55 for the feature-flag idiom.
- **Test scenarios**:
  - Linux target with `features.flatpaks: true` — both entries are managed.
  - Linux target with `features.flatpaks: false` — neither entry is managed; `kleopatra.desktop` is unaffected.
  - Non-Linux target — neither entry is managed, regardless of the flag.
  - A `features` key absent from the render data, or present without `flatpaks` — the render aborts with a `map has no entry for key` template error. chezmoi renders with `missingkey=error`, so the `default dict` form never reaches the lookup and the gate is not fail-safe. This matches every feature flag in the root `.chezmoiignore` and is the wanted behavior for a required committed manifest.
- **Verification**: A scratch-source render matrix over those four cases lists exactly the expected entries. The four native autostart entries appear in every case.

---

## Verification Contract

Never render against the live `$HOME`. Use the scratch-destination recipe from `AGENTS.md`.

| Check | Applies to | Done signal |
|---|---|---|
| `desktop-file-validate` on both `.desktop` files | U1, U2 | Exits 0 with no warnings |
| Scratch-destination `chezmoi managed` listing `.config/autostart` | U1, U3 | Both entries present on a Linux + flatpaks-true render |
| Scratch-source render matrix over the four U3 cases | U3 | Each case lists exactly the expected entries |
| `git diff --check` and `git status` | all | No whitespace errors; only the three intended files changed |
| Live login check | U1 | Telegram appears in the tray with no window after logout and login |

The render matrix runs against a throwaway source tree so `features.flatpaks` and the OS branch can both be varied; the live source is read-only for this check.

The live login check needs the entry deployed, so it runs after `chezmoi apply ~/.config/autostart`. It is a human step: only an operator can end and restart a graphical session.

Preparatory evidence, which does not stand in for that gate: this host runs Plasma under systemd startup, so `systemd-xdg-autostart-generator` turns each `~/.config/autostart/*.desktop` into an `app-<name>@autostart.service` unit and links it into `xdg-desktop-autostart.target.wants/`. Confirming that the generated unit carries the entry's `Exec` line, that it is wanted by that target, and that starting it produces the tray-only result narrows what the login check can still surprise you with. It does not replace it.

---

## Definition of Done

- R1 through R6 hold.
- All five Verification Contract checks pass.
- `dot_config/autostart/discord.desktop` differs from its previous content by exactly one line.
- The Flatpak install script and the four native autostart entries are byte-identical to their previous content.
- No scratch source trees, stub binaries, or throwaway render output remain in the repository or in the working tree.
