---
title: Desktop IR Camera Face Authentication - Plan
type: feat
date: 2026-09-20
topic: desktop-ir-camera-face-auth
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Desktop IR Camera Face Authentication - Plan

## Goal Capsule

- **Objective:** The MSI desktop authenticates its operator by face wherever the fingerprint factor already reaches, with its login greeter still password-only, and a managed host whose infrared camera streams a format other than greyscale is provisioned rather than silently skipped.
- **Means:** Declare the camera, replace the greyscale-only node rule with one that holds for both managed cameras, let a camera whose emitters need no stored configuration reach convergence, and point Howdy at the node in a format that camera actually delivers.
- **Product authority:** Root `AGENTS.md` — the fact registry rules, the password-only greeter boundary, the four skip directions, the no-teardown rule, and the edit-data-not-rendered-targets rule. `STRATEGY.md` for declare-it-as-data and fail-safe defaults.
- **Execution profile:** chezmoi configuration and provisioning work. Proof is render-time verification against a throwaway destination, the repository's own CI gates, and one live apply on the MS-7D91 desktop.
- **Who finishes:** An automated run delivers U1 to U4 through a merged pull request. U5 needs a person at the desktop: enrolling a face is biometric and confirming authentication is interactive.
- **Stop conditions:** Stop and report if the greeter guard resolves `plasmalogin` to a stack the face factor would reach.
- **Open blockers:** None.
- **Supersedes:** the model-keyed emitter-configuration draft written earlier the same day. Hardware measurement on the desktop removed the requirement that draft existed to serve — see Problem Frame.

---

## Product Contract

### Summary

Bring face authentication to the MSI desktop by fixing the one thing that stops the existing mechanism reaching it: the infrared node is identified by a greyscale-only pixel format, and this camera's infrared node advertises no greyscale format. Let a camera whose emitters already work converge without a stored emitter configuration, and give Howdy a capture format this camera can actually deliver.

### Problem Frame

The repository already provisions Howdy, the emitter tool, and the authselect face feature end to end, from declared data. It works on one host. Bringing up a second host exposed that one step of it was written against one camera rather than against the class of hardware the fact describes.

The installer finds the infrared sensor by scanning `/dev/video*` for a node whose only pixel format is `GREY`. The ThinkPad's camera satisfies that. The desktop's Realtek module does not: its infrared node, `/dev/video2`, named `HK Hello CAM: IR Camera`, advertises `MJPG` at 640x480 and `YUYV` at 640x360 and nothing else. The scan therefore finds no node, and the installer leaves through a `harmless` skip that removes its own record — before it sets Howdy's device, before it builds the authselect profile, and before it selects that profile. Declaring the camera alone would deploy the installer and change nothing observable.

Two consequences follow from that same measurement. This camera's infrared emitters already operate: the Microsoft Camera Control extension unit on it reports its face-authentication control at `1 3 2 0 0 0 0 0 0`, which is also that control's default and its maximum, and captured infrared frames alternate between mean brightness 67 and 79 overall while the centre of the frame alternates between 51 and 84 — near-field illumination strobing, the signature this repository already recorded as the success condition on the other host. Nothing needs configuring, so the installer's rule that an emitter configuration must exist before a host is converged would report an outstanding manual step on this host forever. And this camera's `YUYV` path returns corrupted short buffers where `MJPG` streams cleanly, so the format Howdy reads is not incidental.

The greyscale assumption is also written down as fact in several places, including the `irCamera` registry entry that describes a listed camera as one "verified to expose an infrared greyscale stream".

### Key Decisions

- **The infrared node is identified by a rule that holds for the class, not by one camera's pixel format.** Greyscale stays the first signal because it keeps the ThinkPad's choice unchanged; a camera without it falls through to a positional rule. Governs R3.
- **A stored emitter configuration is not a precondition for convergence.** Some Windows Hello cameras ship with their emitter control already at the face-authentication value, so requiring a stored configuration would hold such a host permanently unconverged. Governs R6.
- **The emitter tool and its unit stay provisioned on every eligible host.** Its cost is an idle unit, and removing it would strand the hosts that do need it. Governs R7.
- **An attached declared camera whose node cannot be resolved is an unconverged host, not a final skip.** `harmless` removes its record, which is why this failure was invisible until the second host. Governs R5.
- **Completion means verified on the desktop.** (session-settled: user-directed — chosen over repository-changes-only: the remaining unknowns are properties of this hardware and close in the same act as the verification.) Governs R10.

### Requirements

**Host coverage**

- R1. The MSI desktop's Realtek infrared camera, USB identity `0bda:571d`, is declared in `home/.chezmoidata/.ir-cameras.tsv`, so the `irCamera` fact reads true on that host and `install-system-34-face-auth` is deployed and provisions there.
- R2. The declaration adds a row in the table's existing shape. The hook parser in `.install-prerequisites.sh` matches a whole `vendor<TAB>product` line, so the row carries no extra column.

**Infrared node resolution**

- R3. The infrared node is identified by a rule that resolves both managed cameras: the node that advertises only greyscale when one exists, and otherwise the camera's later video-streaming function. The chosen node is printed.
- R4. Node resolution considers only nodes belonging to an attached camera the repository declared, rather than the first matching node on the host.
- R5. When a declared camera is attached and no node resolves, the host is reported as unconverged through a record `dotfiles-skips` lists, and the authselect feature is still provisioned.

**Emitter expectations**

- R6. A camera whose infrared emitters operate with no stored configuration reaches convergence: no outstanding emitter step is reported for it.
- R7. The emitter tool and its systemd unit remain provisioned, and a camera that does need a stored configuration keeps the behaviour it has today.

**Capture format**

- R8. Howdy reads the infrared node in a format that camera delivers, chosen from what the node advertises rather than assumed.

**Documentation**

- R9. The repository no longer states that a declared infrared camera exposes a greyscale stream.

**Delivery**

- R10. Face authentication is confirmed working on the MSI desktop for a service that includes `system-auth`, and the login greeter there is confirmed password-only.

### Key Flows

- F1. First apply on the desktop
  - **Trigger:** The Realtek identity is added to the table and the operator applies.
  - **Steps:** The fact reads true, so the installer is deployed and runs. It installs the packages and the emitter tool, resolves the infrared node of the declared camera, records Howdy's device and capture format, builds and selects the authselect profile behind the greeter guard, finds the emitters already operating, and reports only the enrollment step.
  - **Outcome:** The factor is enabled and one manual step remains.
  - **Covers R1, R3, R4, R6, R8.**

- F2. A declared camera whose node cannot be resolved
  - **Trigger:** An apply on a host with a declared camera attached whose nodes match no rule.
  - **Steps:** The installer provisions the authselect feature, then leaves through a kept record naming the camera and the nodes it saw.
  - **Outcome:** `dotfiles-skips` reports the host as unconverged until the rule or the hardware changes.
  - **Covers R5.**

- F3. A camera that does need an emitter configuration
  - **Trigger:** An apply on the ThinkPad, or any host whose emitters are dark.
  - **Steps:** Unchanged from today: the committed capture is installed, the unit is started, and an absent configuration reports the `configure` step.
  - **Outcome:** Today's behaviour, unaffected by R6.
  - **Covers R7.**

### Acceptance Examples

- AE1. **Covers R3.** Given a camera whose infrared node advertises only greyscale, when the installer resolves the node, then it chooses that node, exactly as it does today.
- AE2. **Covers R3, R8.** Given a camera whose infrared node advertises only `MJPG` and `YUYV`, when the installer resolves the node, then it chooses the later video-streaming function of that camera and records a capture format that node advertises.
- AE3. **Covers R4.** Given an undeclared camera attached beside a declared one, when the installer resolves the node, then no node of the undeclared camera is chosen.
- AE4. **Covers R5.** Given a declared camera attached whose nodes match no rule, when the installer runs, then the authselect feature is still selected and `dotfiles-skips` lists the host.
- AE5. **Covers R6.** Given a camera whose emitters operate with no stored configuration, when the installer runs after enrollment, then `dotfiles-skips` lists nothing for face authentication.
- AE6. **Covers R7.** Given the ThinkPad's committed capture and its camera, when the installer runs, then the file it receives under `/etc/linux-enable-ir-emitter/` is unchanged.
- AE7. **Covers R10.** Given the desktop after enrollment, when the operator runs `sudo -k` and then a `sudo` command, then the face factor is offered before the password prompt and a successful recognition authenticates.

### Success Criteria

- A render of the installer against a throwaway destination differs from the current render only in the node-resolution, capture-format, and emitter-expectation sections.
- `.ci/check-skip-declarations.sh` passes after a reviewed, explained move of the frozen site matrix.
- After enrollment on the desktop, `dotfiles-skips` reports nothing for `install-system-face-auth`.
- The ThinkPad's `/etc` is unchanged by this work apart from the installer re-running once.

### Scope Boundaries

- Keying a committed emitter capture to the camera model, and making it independent of the USB port, is not in scope. It was the subject of the superseded draft; this camera stores no capture, and the one camera that does has an internal module that never moves. File it if a second camera ever needs a stored capture.
- The set of services the face factor reaches is unchanged. On Fedora the `with-howdy` feature writes `system-auth`, so every service including that stack gains the factor; that scope is already accepted on the ThinkPad.
- The Plasma lock screen is untouched. It authenticates through `password-auth`, which the face profile never writes.
- Face enrollment stays a manual per-user step the installer reports rather than performs.
- Identity keying by vendor and product is a coverage rule, not a device-authenticity control. A substituted camera with the same identity is out of this repository's threat model.

### Dependencies and Assumptions

- The desktop's greeter is `plasmalogin`, whose PAM service substacks `password-auth`, so the shared greeter guard permits the factor there. The guard remains the authority; this is an expectation, not a bypass.
- `v4l2-ctl` is already in the `faceAuth` package list, so format enumeration needs no new dependency.
- The emitter measurement was taken on this host with read-only queries and one capture. It establishes that the emitters operate now; it does not establish that they survive a suspend or a firmware update. R6 makes an unconfigured camera converge, so a later regression would surface as authentication failing rather than as a reported step.
- Howdy converts frames to greyscale itself, so a non-greyscale infrared stream is expected to work. Confirmed only by reading upstream, not by running Howdy on this camera; U5 closes it.

### Sources and Research

- Measured on the MSI desktop this session: `VIDIOC_ENUM_FMT` on `/dev/video2` returns `MJPG` and `YUYV` only; `VIDIOC_ENUM_FRAMESIZES` gives `MJPG` 640x480 and `YUYV` 640x360; `UVCIOC_CTRL_QUERY` on unit 10 selector 6 returns length 9 with current, default and maximum all `1 3 2 0 0 0 0 0 0`; a 10-frame `MJPG` capture has per-frame mean brightness alternating 67/79 with the centre patch alternating 51/84; the `YUYV` path returns corrupted 9152-byte buffers.
- `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl` — the greyscale scan and its `no-grey-video-node` skip sit ahead of the authselect block; the device-path block writes `howdy set device_path`; the pending block decides the manual steps.
- `home/.chezmoidata/facts.yaml` — the `irCamera` fact and the greyscale claim in its `source:` prose.
- `.install-prerequisites.sh` — `usb_device_listed` reads `idVendor` and `idProduct` from `/sys/bus/usb/devices/*/`, the same attributes a video node reaches through its `device` link.
- `.ci/skip-declaration-site-matrix.yaml` — the `install-system-face-auth` owner rows and the `plan_contract` per-direction counts.
- `docs/solutions/integration-issues/howdy-face-authentication-authselect-pam-scoping.md` — the original bring-up, including the frame-mean diagnostic this plan's measurement repeats.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The node rule is greyscale first, then the camera's later video-streaming function.** Among the video nodes of one declared attached camera, consider only nodes that enumerate at least one capture format. Prefer a node whose only format is `GREY`. Otherwise take the node whose by-path USB interface component is the highest — the infrared function sits on `:1.2` against the RGB `:1.0` on both managed cameras. Implements R3.
- KTD2. **A video node is tied to a declared identity through sysfs.** The node's `/sys/class/video4linux/<node>/device` is its USB interface; that directory's parent carries `idVendor` and `idProduct`, the attributes the hook already reads. No udev query is needed. Implements R4.
- KTD3. **A format enumeration that fails is an error, not an empty result.** `v4l2-ctl` exiting non-zero is printed and resolves no node, so a broken tool never reads as a camera with no formats. Implements R3, R5.
- KTD4. **Howdy's capture format follows the chosen node.** When the node advertises no greyscale format, the installer also sets Howdy's MJPEG capture option; when it does, it leaves the option alone. This is per-host state derived from the same enumeration, not a new declaration. Implements R8.
- KTD5. **The emitter step is reported only when the camera needs one.** A camera converges when a stored configuration is present and applied for that camera, or when its emitters are already operating. The installer decides the second case from the same frame-brightness test this plan's measurement used, over a short capture from the chosen node, decoded to greyscale raster before it is measured — a node that advertises only `MJPG` yields JPEG payloads, not raster, so measuring raw bytes would be meaningless. Emitters count as operating when consecutive frame means differ by at least 8 or the highest frame mean is at least 20; a dark sensor measured 6.4 on the other host with room lighting visible, the desktop alternates 67 and 79, and the ThinkPad alternated 30 and 103. The alternation is the primary signal, because ambient infrared can raise a dark sensor's absolute level. Implements R6.
- KTD6. **The unresolved-node exit becomes `operator-blocking` and moves behind the authselect block.** `harmless` claims the host can never satisfy the condition and removes its record, which is how this failure stayed invisible; moving the exit after the profile selection keeps the factor provisioned per R5. `transient-tolerable` exits 1 and would strand phases 50 to 90.
- KTD7. **The matrix move is one site changing direction, not a site count change.** `no-grey-video-node` becomes `no-infrared-node` with direction `operator-blocking`, so `classified_owners` and the instance totals stay at their current values. What moves is the live per-direction tally, `audited_directions`: `harmless` 34 to 33 and `operator-blocking` 20 to 21, with the `harmless` divergence row's audited figure and its reason text following. `plan_contract.harmless` stays 41: it is a frozen figure from the feedback-sweep plan Appendix that `.ci/test-capability-cache.sh` asserts literally, not a live count.

### Assumptions

- KTD1's positional fallback is verified against exactly two cameras. A third camera that breaks it moves the rule into declared data; `.ir-cameras.tsv` cannot carry it, because its parser matches a whole line, so that would be a new data file.
- KTD5's brightness test needs a capture from the infrared node during the apply. Whether a short capture is reliable on a cold-booted hub-chain camera is an implementation-time question; a conservative reading treats an inconclusive capture as "needs a configuration", which preserves today's behaviour.

### Sequencing

U1 is independent. U2 depends on U1, because its fixtures resolve against the declared Realtek identity. U3 and U4 build on U2. U5 runs on the desktop after U1 to U4 are merged and applied.

---

## Implementation Units

### U1. Declare the Realtek camera and correct the greyscale prose

- **Goal:** `irCamera` reads true on the MSI desktop, and the repository stops describing a declared infrared camera as a greyscale one.
- **Requirements:** R1, R2, R9.
- **Dependencies:** None.
- **Files:** `home/.chezmoidata/.ir-cameras.tsv`, `home/.chezmoidata/facts.yaml`, `.install-prerequisites.sh`, `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl`.
- **Approach:**
  1. Add the `0bda`/`571d` row to the table, keeping the two-column shape.
  2. Rewrite the `irCamera` `source:` prose so it describes a verified infrared camera without naming a pixel format, and do the same for the table comment in `.install-prerequisites.sh` and the installer's own header comment.
  3. Leave root `AGENTS.md` alone. Its only mention of greyscale records how the ThinkPad's emitter control was verified on hardware, which stays true; it defines nothing about what a declared camera exposes.
- **Patterns to follow:** The fingerprint-reader table beside it; the existing fact prose for `fingerprintReader`.
- **Test scenarios:**
  - `.ci/test-host-fact-probes.sh` resolves `irCamera=true` for the new row.
  - The table still parses under `usb_device_listed` with two rows.
  - `Test expectation: none` for the prose changes beyond the render gate.
- **Verification:** The hook fact test passes and a render of the installer is unchanged except in comments.

### U2. Resolve the infrared node by camera, not by pixel format

- **Goal:** The installer finds the infrared node of a declared attached camera on both managed cameras, and says which node it chose.
- **Requirements:** R3, R4, R5. Covers F1, F2, AE1, AE2, AE3, AE4.
- **Dependencies:** U1.
- **Files:** `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl`, `.ci/skip-declaration-site-matrix.yaml`, `.ci/check-skip-declarations.sh`, `.ci/test-capability-cache.sh`, `.ci/test-face-auth-node.sh` (new), `.github/workflows/ci.yml`.
- **Approach:**
  1. Replace the host-wide greyscale scan with the KTD1 rule over the nodes of each declared attached camera, resolved through KTD2.
  2. Print the chosen node and the camera it belongs to.
  3. Move the unresolved-node exit to after the authselect selection and convert it to the KTD6 site. Everything that depends on a resolved node — Howdy's device path and capture format in U4, and the emitter expectation in U3 — runs only when one resolved, so a host with no node never has an empty value written into `/etc/howdy/config.ini`.
  4. Apply the KTD7 matrix move: rename the owner, change its direction, move `audited_directions` `harmless` 34 to 33 and `operator-blocking` 20 to 21, and update the `harmless` divergence row's audited figure and the clause in its reason that describes the site as a camera exposing no greyscale stream. Leave `plan_contract`, the instance totals and the owner totals alone, and confirm no frozen total in `.ci/check-skip-declarations.sh` or `.ci/test-capability-cache.sh` moves.
  5. Give the script overridable roots for `/dev` and `/sys` so the new test can drive the rendered text against a fixture tree; the exact seam is an implementation choice.
- **Execution note:** Write the fixtures first. The discriminator is the part no host but the desktop can prove, and both camera shapes are known precisely enough to fixture.
- **Patterns to follow:** `.ci/test-android-skill-ownership.sh` for running a rendered script against stubs; `render()` in `.ci/lib/render-gate-helpers.sh`.
- **Test scenarios:**
  - Covers AE1. A `30c9:0052` fixture whose `:1.2` node lists only `GREY` chooses that node.
  - Covers AE2. A `0bda:571d` fixture with `MJPG`/`YUYV` on `:1.0` and `:1.2`, and format-less metadata nodes, chooses the `:1.2` node.
  - Covers AE3. An undeclared camera with a `GREY` node attached beside a declared one is never chosen.
  - Covers AE4. A declared camera with no capture-capable node writes the kept record and exits 0, after the authselect block ran.
  - A `v4l2-ctl` that exits non-zero prints the error and resolves no node.
  - The chosen node and its camera appear in the output.
- **Verification:** The rendered installer reaches the authselect selection on a host with no greyscale node. `.ci/check-skip-declarations.sh` passes with the renamed site and unchanged totals.

### U3. Converge a camera whose emitters already work

- **Goal:** A host whose infrared emitters operate without a stored configuration stops reporting an emitter step.
- **Requirements:** R6, R7. Covers F1, F3, AE5, AE6.
- **Dependencies:** U2.
- **Files:** `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl`, `.ci/test-face-auth-node.sh`.
- **Approach:**
  1. Scope the stored-configuration path to the resolved camera. Today the copy loop installs every file in the source tree by basename and the pending check greps the whole `/etc/linux-enable-ir-emitter/` directory, so the ThinkPad's committed capture would land on the desktop and its `status: start` would read as this camera being configured — the brightness test would never run. Install only a capture whose name matches the resolved device, and check `status: start` under that one name.
  2. When no capture matches the resolved device, capture a short burst from the chosen node, decode it to greyscale raster, and apply the KTD5 thresholds. Treat emitters as operating when the test passes, and report no emitter step.
  3. Treat an inconclusive or failed capture as needing a configuration, so today's behaviour is the fallback.
  4. Leave the emitter tool installation and unit enable untouched.
- **Patterns to follow:** The frame-mean diagnostic recorded in `docs/solutions/integration-issues/howdy-face-authentication-authselect-pam-scoping.md`.
- **Test scenarios:**
  - Covers AE5. A fixture whose capture alternates in brightness reports no emitter step.
  - A fixture whose capture is uniformly dark, at a mean below both thresholds, reports the `configure` step.
  - Covers AE6. A ThinkPad-shaped fixture with a matching committed capture installs it and never runs the brightness test.
  - A fixture attached to the Realtek camera with only the ThinkPad capture committed installs nothing and still reaches the brightness test.
  - A capture that fails, or one whose decode produces no frames, reports the `configure` step and prints why.
- **Verification:** Against the fixtures, only the dark and failed cases report an emitter step, and the ThinkPad fixture's installed file is byte-identical.

### U4. Give Howdy a format this camera delivers

- **Goal:** Howdy reads the chosen node in a format that node advertises.
- **Requirements:** R8. Covers AE2.
- **Dependencies:** U2.
- **Files:** `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl`, `.ci/test-face-auth-node.sh`.
- **Approach:**
  1. Set Howdy's device path as today, and only on the path where a node was actually resolved.
  2. When the chosen node advertises no greyscale format, also assert Howdy's MJPEG capture option; when it does advertise greyscale, leave that option untouched so the ThinkPad is unaffected.
  3. Skip both writes when the current values already match, keeping the apply idempotent.
- **Patterns to follow:** The existing read-then-compare around `howdy set device_path`.
- **Test scenarios:**
  - A greyscale-node fixture issues no MJPEG option write.
  - A non-greyscale-node fixture issues one, and a second run issues none.
  - An unchanged device path issues no `howdy set`.
  - A fixture where no node resolved issues neither write, leaving `/etc/howdy/config.ini` untouched.
- **Verification:** On both fixtures the second run performs no write.

### U5. Verify on the MSI desktop

- **Goal:** Face authentication works on the desktop, and the greeter there is still password-only.
- **Requirements:** R10. Covers AE7.
- **Dependencies:** U1 to U4 merged and applied.
- **Files:** None. This unit changes no file.
- **Approach:** This unit is operator-completed; an agent can prepare and read, but cannot perform steps 2 and 3.
  1. Apply from a local console. Confirm the chosen node is the `:1.2` link of `0bda:571d`, that the greeter guard permitted the factor, that the apply output prints the enrollment step, and that `dotfiles-skips` lists no face-authentication entry. The enrollment step leaves through `done_here`, which prints once and removes its record, so it is an apply-output signal rather than a `dotfiles-skips` one.
  2. Run `sudo howdy add` and enroll.
  3. Run AE7, then confirm the greeter offers only a password, then reboot and repeat AE7.
  4. Record whether `pam_howdy` falls through without a noticeable delay with the camera covered and with it unplugged.
- **Execution note:** Record each Dependencies-and-Assumptions item as observed fact in the pull request description. A finding that contradicts a KTD reopens that KTD.
- **Test scenarios:**
  - Covers AE7. `sudo -k` then `sudo true` authenticates by face.
  - The same after a reboot with no apply in between.
  - The login greeter offers only a password.
  - With the camera covered, and separately with it unplugged, `sudo` falls through to the password prompt; both delays are recorded.
- **Verification:** `dotfiles-skips` reports nothing for `install-system-face-auth` on the desktop, and a second apply writes nothing.

---

## Verification Contract

| Gate | Command or workflow | Proves | Units |
|---|---|---|---|
| Template render | The recipe in root `AGENTS.md` under "Verification (never deploy live `$HOME`)": scratch directory, stub `op`, empty config, throwaway `--destination`, `--source "$PWD"`, `PATH="$scratch/bin:/usr/bin:/bin"`, `execute-template` with a stdin path starting `home/` | The installer renders on every Fedora target; rendered scripts are compared as text on both sides | U1 to U4 |
| Host fact | `.ci/test-host-fact-probes.sh` | Both table rows resolve `irCamera=true` | U1 |
| Skip declarations | `.ci/check-skip-declarations.sh` | No bare conditional `exit 0`; the installer's site count is unchanged and the renamed site carries its new direction | U2 |
| Skip partials | `.ci/test-skip-declaration-gates.sh`, `.ci/test-dotfiles-skips.sh` | The kept record is listed while outstanding and retired on convergence | U2, U3 |
| Frozen fan-outs | `.ci/test-capability-cache.sh` and the `FROZEN` block of `.ci/check-skip-declarations.sh` | The owner and instance totals did not move; only the per-direction `harmless` count did | U2 |
| Node and emitter behavior | `.ci/test-face-auth-node.sh` | The rendered installer against both camera fixtures: node choice, capture format, emitter expectation, kept record | U2, U3, U4 |
| CI wiring | `.ci/test-ci-wiring.sh` | The new gate is invoked by a workflow | U2 |
| Greeter boundary | `.ci/test-fingerprint-greeter-guard.sh` | Unchanged: `plasmalogin` permits, unknown greeters withhold | U2 |
| Hygiene | `git diff --check`, `git status`, a diff limited to this plan's files | No stray edits | all |
| Workflows | `render-dotfiles.yml` and `ci.yml`, each watched to terminal success after every push | The full render matrix and the `delivery` aggregate | all |
| Desktop | U5's steps from a local console | R10 and AE7 on real hardware | U5 |

Disclosed side effects: the installer's rendered content changes, so it re-runs once on every `irCamera` host, including the ThinkPad, where it re-asserts values that already match and starts an already-running unit. No network service restarts. The archive comparison in root `AGENTS.md` omits scripts, so the installer is compared as rendered text.

---

## Definition of Done

**An automated run can satisfy**

- R1 to R9 are implemented, and every gate in the Verification Contract except the Desktop row is green.
- U1 to U4 are merged through a pull request whose `render-dotfiles.yml` and `ci.yml` runs reached terminal success.
- The matrix move is explained in the pull request description: which site was renamed, its new direction, and why no total moved.
- `.ci/test-face-auth-node.sh` covers AE1 to AE6 against fixtures.
- No abandoned-attempt code, fixture, or comment from a discarded approach remains in the diff.

**Only the operator can complete**

- R10, with AE7 observed on the MSI desktop before and after a reboot.
- The greeter on the desktop confirmed password-only.
- The camera-covered and camera-absent fall-through delays recorded.

The change is not complete until both lists are closed. A merged U1 to U4 with U5 open is a provisioned desktop with one reported manual step, not a finished plan.

| Unit | Done when |
|---|---|
| U1 | The Realtek row resolves `irCamera=true` in the hook test, and no fact, comment, or document names a pixel format as the infrared signal |
| U2 | Both camera fixtures choose the `:1.2` node, the installer reaches authselect without a greyscale node, and the skip gates pass with unchanged totals |
| U3 | Only the dark and failed fixtures report an emitter step, and the ThinkPad fixture's installed file is byte-identical |
| U4 | The non-greyscale fixture asserts the MJPEG option once and not twice; the greyscale fixture never asserts it |
| U5 | The operator list above is closed |
