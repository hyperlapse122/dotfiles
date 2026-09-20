---
title: Howdy Face Authentication Reaches Only the system-auth Services, Through a Derived authselect Profile
date: 2026-09-16
category: integration-issues
module: auth
problem_type: architecture_pattern
component: authentication
severity: medium
applies_when:
  - "Adding or debugging a PAM authentication factor on a Fedora host this repository manages"
  - "Deciding which services a biometric factor may reach, and why the Plasma lock screen and polkit are excluded"
  - "Bringing up an infrared camera whose emitter stays dark, or capturing its emitter control as system data"
  - "Choosing a Howdy package source on a Fedora release that ships no python3-dlib"
  - "Adding a declared hardware fact plus a run_onchange_ installer with declared skips"
tags:
  - howdy
  - authselect
  - pam
  - fedora
  - kscreenlocker
  - polkit
  - ir-camera
  - linux-enable-ir-emitter
---

# Howdy Face Authentication Reaches Only the system-auth Services, Through a Derived authselect Profile

## Context

The ThinkPad X1 Carbon Gen 11 carries an infrared camera next to its RGB one, and the
request was to authenticate with a face through Howdy, managed as a dotfiles component.
The scope offered at the start was "sudo, lock screen and polkit". The investigation
below shows that two of those three cannot run Howdy on Fedora 44 with Plasma 6.7, and
why the design lands the factor exactly where the fingerprint factor already lives.
`AGENTS.md` and the installer's own header state the conclusions; this learning keeps the
evidence and the rejected alternatives, which the tree cannot recover.

## Guidance

### Which PAM service reaches which stack

Read off the live host (Fedora 44, `plasma-login-manager` greeter), the auth phase of
each service resolves as follows:

| Service file | Auth phase |
|---|---|
| `/etc/pam.d/sudo`, `/usr/lib/pam.d/polkit-1`, `/etc/pam.d/kscreensaver`, `/etc/pam.d/kcheckpass` | `include system-auth` |
| `/etc/pam.d/kde` (Plasma lock screen, password) | `substack password-auth` |
| `/etc/pam.d/kde-fingerprint` (Plasma lock screen, fingerprint) | `substack fingerprint-auth` |
| `/usr/lib/pam.d/plasmalogin` (login greeter) | `substack password-auth` |

authselect owns `system-auth`, `password-auth` and `fingerprint-auth`; the base template
is `/usr/share/authselect/default/local/system-auth`, whose fingerprint line carries
`{include if "with-fingerprint"}`. authselect does not validate feature names
(`authselect test local with-fingerprint with-bogus` exits 0), so a derived profile may
introduce a new feature name.

### How pam_howdy runs, and where that leaves it inert

Per this session's reading of the Howdy 3.0.0 RPM (strings in
`/usr/lib64/security/pam_howdy.so` and the Python under
`/usr/lib/python3.14/site-packages/howdy/`), the module spawns
`/usr/bin/python3 .../howdy/compare.py` as the calling process's user, reads
`/etc/howdy/config.ini` and `/etc/howdy/models/<user>.dat`, and opens the camera named by
`device_path`. Three consequences follow:

- **sudo, su, login**: the caller is root; the recogniser reads the model and the camera.
  Verified on this host: `sudo` printed `Identified face as h82`.
- **polkit**: `polkitd` runs as user `polkitd` under SELinux `policykit_t`
  (`ps -o user,label -C polkitd`). The spawned recogniser cannot open the camera, so a
  `sufficient` pam_howdy fails through to pam_fprintd and pam_unix. Inert, not harmful.
- **Plasma lock screen**: per this session's reading of
  `https://invent.kde.org/plasma/kscreenlocker/-/raw/master/greeter/pamauthenticators.cpp`,
  the greeter's `PamAuthenticators` constructor queues `onAuthenticatorChanged()`, which
  ends in `startAuthenticating()`, which calls `tryUnlock()` on both the interactive `kde`
  and the non-interactive `kde-fingerprint` authenticator the moment the greeter exists;
  only a grace-lock defers it, and an explicit lock has none. A face module in
  `password-auth` or `fingerprint-auth` would therefore unlock the screen for whoever just
  pressed Meta+L. The lock screen keeps fingerprint and password.

The factor therefore belongs in `system-auth` alone, which is the set `AGENTS.md` already
accepts for the fingerprint factor, and the greeter (`password-auth`) stays password-only
by construction. The shared predicate `greeter_would_gain_module` in
`.chezmoitemplates/pam-greeter-guard.sh.tmpl` still proves that against the rendered
profile before selecting it, bound per module and per profile:

```bash
if greeter_would_gain_module 'pam_howdy\.so' "custom/${FACE_PROFILE}" "${features[@]}"; then
  # declared harmless skip: the profile is built but not selected
fi
```

### The derived authselect profile

Stock authselect has no face feature and this repository forbids writing PAM files, so
`.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl` builds
`/etc/authselect/custom/face-auth` from the stock `local` profile: every file is a symlink
back to the base (the shape `authselect create-profile --symlink-*` produces, so base
updates propagate), except `README`, which documents the feature, and `system-auth`, which
gains one templated line ahead of the fingerprint one:

```bash
howdy_line='auth        sufficient                                   pam_howdy.so                                           {include if "with-howdy"}'
awk -v line="$howdy_line" '
    /^auth[[:space:]].*pam_fprintd\.so/ && !done { print line; done = 1 }
    { print }
    END { if (!done) exit 3 }
  ' "${AUTHSELECT_BASE}/system-auth" >"${profile_build}/system-auth"
```

A base without the pam_fprintd anchor fails the build (exit 3) rather than yielding a
silently featureless profile. The installer then reads `authselect current --raw`,
keeps every feature the host already carries, adds `with-howdy`, refuses with a declared
operator-blocking skip when `authselect check` fails, and runs
`authselect select custom/face-auth <features>`.

### Read authselect unprivileged: sudo pollutes captured output here

Every `$(sudo …)` on this host is unreliable once the sudo stack carries pam_fprintd:
sudo prints the localized fingerprint prompt and its timeout notice on the captured
stream, even with `2>/dev/null`. The first run captured
`인식기에 손가락을 올려놓으십시오 인증 시간 초과 local …` as the profile id and
`authselect select` failed on "unknown feature 인식기에"; a later run read the prompt as
the content of an empty configuration directory. Two rules follow:

- `authselect current`, `authselect check` and `authselect test` need no root
  (`authselect.conf` and the profile trees are world-readable); run them unprivileged.
- When a privileged probe is unavoidable, consume its exit status only, never its output:
  `"${SUDO[@]}" sh -c 'grep -lq "status: start" /etc/linux-enable-ir-emitter/* 2>/dev/null'`.

### The infrared emitter: diagnosis, the failing configure dialogue, and the captured control

On THIS camera the IR sensor is the `/dev/video*` node whose only pixel format is `GREY`
(`v4l2-ctl -d $node --list-formats`); its stable name is the `/dev/v4l/by-path/…-video-index0`
symlink, which is what `howdy set device_path` records. A GREY frame captured before any
emitter work had a mean pixel value of 6.4 with the face nearly black while the ceiling
light was visible: the sensor works, the emitters are dark.

Greyscale is not the general rule, and treating it as one cost a second host its
provisioning. The Realtek `0bda:571d` module of the MS-7D91 desktop streams `MJPG` and
`YUYV` on its infrared node and no greyscale format at all, so the scan found nothing and
the installer left through its harmless skip before selecting the authselect profile. The
installer now identifies the node within a declared attached camera — greyscale first,
otherwise the camera's later video-streaming function — and decodes the capture before
measuring it. That camera also needed no emitter configuration: its Microsoft Camera
Control extension unit reports the face-authentication control at `1 3 2 0 0 0 0 0 0`,
which is that control's default AND its maximum, and its frames already alternate 67/79
overall with the centre alternating 51/84. Where the ThinkPad had to be told to turn its
emitters on, that one ships with them on.

```bash
v4l2-ctl -d /dev/video2 --set-fmt-video=width=640,height=360,pixelformat=GREY \
  --stream-mmap --stream-count=10 --stream-to=ir.raw
python3 -c "d=open('ir.raw','rb').read(); n=640*360; print([round(sum(d[i*n:(i+1)*n])/n,1) for i in range(len(d)//n)])"
```

`linux-enable-ir-emitter configure` (6.1.2) fails on this camera at every control it
tries with `Impossible to reset the instruction: unit: 4, selector: N`; the documented
remedy is a cold boot, and each retry only advances one selector. The maintainer's note in
an upstream issue that "the control that enables the emitter is often unit 7, selector 6,
`1 3 2 0 0 0 0 0 0`" matched an entry in the generated file. Setting that entry to
`status: start` with that value and running `linux-enable-ir-emitter run` made the frame
means alternate `30.1, 103.7, 30.1, 103.1, …`: the emitter blinks, which is the behaviour
Windows Hello cameras expect. Upstream documents that files under
`/etc/linux-enable-ir-emitter/` are save-and-restore data, so the working file is committed
as `system/linux/etc/linux-enable-ir-emitter/<v4l by-path device>` and the installer lands
it before the emitter unit starts. Only a file carrying `status: start` counts: a failed
configure leaves `idle`/`disable` residue, and the installer keeps reporting the manual
step for that. The face model in `/etc/howdy/models/` is biometric and stays a manual
per-user `sudo howdy add`; the user chose not to keep it in the repository even encrypted.

### Package source

Fedora 44 ships no `python3-dlib`, so `principis/howdy-beta` (Howdy 3.0.0 requiring
`python3dist(dlib)`) does not install, and the upstream-documented `principis/howdy` is the
Python-2-era 2.6.1. `starfish/howdy-beta` carries the same 3.0.0 spec plus `dlib 20.0`
for fedora-44 and is the source in `.chezmoidata/system.yaml`. `ronnypfannschmidt/howdy-beta`
adds a `howdy-authselect` path unit that patches PAM files behind authselect's back; rejected
for that reason. The emitter tool's 7.0 line is prerelease-only and moved to a pam_exec
per-authentication model; 6.1.2's systemd tarball is pinned in the release lock.

### Repository mechanics for a declared hardware fact plus a run_onchange_ installer

- Declare the camera in `.chezmoidata/.ir-cameras.tsv` (vendor/product), register
  `irCamera` in `.chezmoidata/facts.yaml`, probe it through `usb_device_listed` in
  `.install-prerequisites.sh`, and add the fact to the fixtures in
  `.ci/test-fedora-fact-block-baseline.sh` and `.ci/test-jetson-installer-render.sh`,
  which enumerate every hook fact.
- Register the external tool in `packages/release-lock/src/registry.ts` and the
  `EXPECTED` table of `packages/release-lock/test/registry.test.ts` (explicit `null` for
  platforms it does not build), then
  `bun run packages/release-lock/src/cli.ts --only <tool> --out .chezmoidata/releases.json`.
- Every declared skip site needs an owner row in `.ci/skip-declaration-site-matrix.yaml`
  (normalized predicate, its sha256, continuation digest, form, direction, probe and
  placement for transient-blocking), the script's instance in each shared guard's list,
  the totals, counters and divergence prose, and the `FROZEN` totals in
  `.ci/check-skip-declarations.sh`. The declaration sentinel must be the first line of its
  branch: a `printf` between the `if` and the declaration fails as "sentinel does not open
  the branch (relocated)". Run the checker; its messages name every missing row.
- `fingerprint.tmpl` fails on a glob that matches nothing, so a data directory that may be
  empty on some branches is hashed behind a template-level `glob` guard.

## Why This Matters

Repeating the investigation means re-reading four PAM files, a kscreenlocker source file,
the Howdy RPM and three COPRs, and the emitter tool's issue tracker. Getting it wrong is
worse than slow: a face module in `password-auth` unlocks the screen for the person who
locked it, a `$(sudo …)` that captures a fingerprint prompt selects a broken authselect
profile, and a failed emitter configure leaves residue that reads as success.

## When to Apply

- Adding any PAM factor on Fedora: derive an authselect profile, keep the factor in
  `system-auth`, and prove the greeter stack clean with the shared predicate.
- Reading system state from a script that also escalates: never trust captured sudo output
  on a host whose sudo stack prompts.
- Bringing up another laptop's IR camera: diagnose with the frame-mean capture, try the
  unit 7 selector 6 control before the configure dialogue, and commit the resulting file.

## Examples

Rendered `system-auth` of the derived profile on this host (`with-fingerprint` and
`with-howdy` selected), face first, then finger, then password:

```text
auth        required                                     pam_env.so
auth        required                                     pam_faildelay.so delay=2000000
auth        sufficient                                   pam_howdy.so
auth        sufficient                                   pam_fprintd.so
auth        sufficient                                   pam_unix.so nullok
auth        required                                     pam_deny.so
```

The captured emitter file's active entry:

```yaml
- status: start
  unit: 7
  selector: 6
  current:
    - 1
    - 3
    - 2
    - 0
    - 0
    - 0
    - 0
    - 0
    - 0
```

## Related

- `docs/solutions/integration-issues/chezmoi-worktree-root-etc-file-deployment.md`: how
  root-owned `/etc` files and onchange scripts behave when applied from a worktree.
- `.chezmoiscripts/30-linux/run_onchange_after_install-system-32-fingerprint.sh.tmpl`:
  the fingerprint installer the face installer mirrors, now sharing the greeter guard.
- GitHub #358 and #362: the fingerprint-through-authselect change and its scope amendment.
