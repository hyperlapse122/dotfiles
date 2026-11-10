---
title: Rootless Podman pause process started inside an agent bubblewrap sandbox poisons the host Podman service
date: "2026-09-28"
category: integration-issues
module: T3 Code desktop package (packages/t3code.nix) and rootless Podman
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "Testcontainers POST /images/create returns 500: no policy.json file found at any of the following: /home/h82/.config/containers/policy.json, /etc/containers/policy.json"
  - "podman pull fails with: potentially insufficient UIDs or GIDs available in user namespace (requested 0:42 for /etc/shadow) ... lchown /etc/shadow: invalid argument"
  - "podman info warns: cannot find UID/GID for user h82: open /etc/subuid"
  - "The host /etc has /etc/containers/policy.json and a subuid entry for h82, yet Podman reports both missing"
root_cause: config_error
resolution_type: config_change
related_components:
  - infrastructure
  - testing_framework
retire_when: "T3 Code no longer runs agent terminals inside a bubblewrap FHS sandbox; check whether packages/t3code.nix still builds with appimageTools.wrapType2 and a T3 Code agent terminal still shows a tmpfs /etc in findmnt"
tags: ["podman", "rootless", "bubblewrap", "orca", "t3code", "pause-process", "user-namespace", "container-host", "testcontainers"]
---

# Rootless Podman pause process started inside an agent bubblewrap sandbox poisons the host Podman service

## Problem

Orca IDE, where this was first seen, shipped as a bubblewrap FHS sandbox, and its agent terminals inherited that sandbox. Orca has since been removed (`packages/orca.nix`), but T3 Code's `appimageTools.wrapType2` wrapper in `packages/t3code.nix` applies the same sandbox to its agent sessions, so the lesson and the mitigation carry over; the Orca-specific details below are kept as history. When a local rootless `podman` or `docker` command runs there first, it creates the per-user pause process inside the sandbox. After that, the host's `podman.service` joins that pause process's namespaces and can no longer see the host's `/etc/containers` or `/etc/subuid` (issue #121).

## Symptoms

- Testcontainers' `POST /images/create` returned HTTP 500. `journalctl --user -u podman.service` logged `no policy.json file found at any of the following: /home/h82/.config/containers/policy.json, /etc/containers/policy.json`.
- After the user created `~/.config/containers/policy.json` by hand, `podman pull docker.io/library/postgres:17-alpine` failed with `potentially insufficient UIDs or GIDs available in user namespace (requested 0:42 for /etc/shadow): Check /etc/subuid and /etc/subgid ... lchown /etc/shadow: invalid argument`.
- `podman info` warned `cannot find UID/GID for user h82: open /etc/subuid`.
- The failure was in the host's user service, not in the sandbox, so it also hit clients that talk to the socket from outside Orca.

## What Didn't Work

- **The fix proposed in the issue.** Issue #121 suggested enabling `virtualisation.containers` and `autoSubUidGidRange`. Both were already in effect: `modules/nixos/services/podman.nix` enables `virtualisation.podman` (which pulls in the containers configuration) and sets `users.users.${config.my.user.name}.autoSubUidGidRange = true`. On the real host, `/etc/containers/policy.json` existed and `/etc/subuid` contained `h82:100000:65536`.
- **Checking `/etc` from an Orca terminal.** `ls /etc/containers` in an Orca terminal fails, which looks like it confirms the issue. The files only seem missing because that shell runs inside the sandbox. A host-side check shows them:

  ```sh
  systemd-run --user --wait --pipe --quiet /run/current-system/sw/bin/sh -c 'ls /etc/containers'
  ```

  A bare `sh` in `systemd-run` fails with status `203/EXEC`, because the transient unit has no `PATH`. Use the absolute path.
- **Hand-writing `~/.config/containers/policy.json`.** That got past the first error, but the next one, missing subuid ranges, comes from the same poisoned namespace. A user-level file cannot supply it.

## Solution

### Diagnosis

Inside an Orca terminal:

- `findmnt /etc` shows a `tmpfs` owned by `uid=1000`.
- `/etc/static` is a symlink to `/.host-etc/static`.
- `/proc/self/status` shows `NoNewPrivs: 1`, so the setuid `newuidmap`/`newgidmap` helpers cannot run.
- `/proc/self/uid_map` is `1000 1000 1`.

This matches the nixpkgs bubblewrap FHS builder. It mounts `--tmpfs /etc` (`pkgs/build-support/build-fhsenv-bubblewrap/default.nix:311`), bind-mounts the real host `/etc` at `/.host-etc` (`default.nix:214-218`), and symlinks back only the entries on a fixed allow-list, `etcBindEntries` (`default.nix:87-134`, linked at `default.nix:226-232`). That list includes `static`, `passwd`, `group`, and `shadow`. It does not include `containers`, `subuid`, or `subgid`.

The pause process gave the sandbox away:

- `cat $XDG_RUNTIME_DIR/libpod/tmp/pause.pid` pointed to a process whose command was `docker`. It started at 17:48:43, 9 seconds before `podman.service` started at 17:48:52.
- `/proc/<pid>/uid_map` was `0 1000 1`, a single-ID map with no subuid range.
- `/proc/<pid>/root/etc/static` resolved to `/.host-etc/static`, so its root was the sandbox root.
- Its environment carried `ORCA_*` variables.

Rootless Podman keeps one pause process per user to hold the user and mount namespaces. Every later rootless Podman process joins it, including `podman system service` behind `podman.service`. The host service therefore inherited the sandbox's `/etc` and its one-ID user namespace. That accounts for both the missing `policy.json` and the `lchown /etc/shadow` failure: GID 42 (`shadow`) has no mapping.

### Fix

Before, `packages/orca.nix` (since removed) passed no Podman setting into the sandbox, so `podman` and `docker` (through `dockerCompat`) ran locally inside bubblewrap.

After, the `extraBwrapArgs` list in `packages/orca.nix` carried the setting. `packages/t3code.nix` carries the same entry today, next to `T3CODE_DISABLE_AUTO_UPDATE` and `SSL_CERT_FILE`:

```nix
extraBwrapArgs = [
  ''--setenv CONTAINER_HOST "unix://$XDG_RUNTIME_DIR/podman/podman.sock"''
];
```

nixpkgs writes `extraBwrapArgs` unquoted into the bwrap `cmd` array of the generated launcher script (`default.nix:330`). As a result, `$XDG_RUNTIME_DIR` expands when Orca starts, not at build time. When `CONTAINER_HOST` is set, Podman defaults to `--remote`. Every `podman` and `docker` call inside Orca then goes to the host's rootless socket, the same one Home Manager exports as `DOCKER_HOST = "unix://\${XDG_RUNTIME_DIR}/podman/podman.sock"` (`linuxSessionVariables` in `home/h82/dev/containers.nix`), and never creates a pause process inside the sandbox. The comment above `extraBwrapArgs` in `packages/t3code.nix` records why.

### Clearing already-poisoned state

The wrapper change does not fix a pause process that already exists. From a **host** terminal, not an Orca one:

```sh
podman system migrate   # or: kill "$(cat "$XDG_RUNTIME_DIR/libpod/tmp/pause.pid")"
```

Then restart the app (Orca then, T3 Code now) so it runs the new wrapper.

### Verification (this session)

After the stale pause process was killed, with `CONTAINER_HOST` exported by hand in an existing Orca terminal to stand in for the new wrapper (Orca itself was not restarted):

- `podman info` inside the Orca terminal reported `ServiceIsRemote: true`.
- The host's UIDMap was `[{0 1000 1} {1 100000 65536}]`.
- `podman pull alpine:3.20` succeeded.
- `docker run --rm alpine:3.20 cat /etc/alpine-release` printed `3.20.10`.
- The new pause process was created on the host, not inside the sandbox.

## Why This Works

The fault is not in the host's configuration. It is in which process creates the shared namespace holder first. The sandbox cannot build a correct rootless user namespace: its `/etc` lacks `subuid`/`subgid`, and `no_new_privs` blocks the setuid ID-mapping helpers. Because Podman reuses the pause process, one bad start stays in place for the rest of the user session. Remote mode means Orca never starts a local Podman at all, so the host service's own pause process, created with the host's `/etc` and full subuid range, is the only one.

Trade-off: Podman's local-only subcommands (`podman unshare`, `podman mount`, `podman system migrate`, `podman system reset`) do not work inside Orca terminals. Run them from a host terminal.

## Prevention

- **Repository check.** The `orca-desktop` check in `flake.nix` read the materialized `bin/orca-ide` launcher, not the option value. Today the `t3code` check in `flake.nix` does the same for `bin/t3code-desktop`. It greps the `--setenv CONTAINER_HOST` line, `eval`s it under the fake `XDG_RUNTIME_DIR=/run/user/4242` (`fakeRuntimeDir`), and checks that the expanded value equals `unix:///run/user/4242/podman/podman.sock` (matching `linuxSessionVariables.DOCKER_HOST` in `home/h82/dev/containers.nix`, which `tests/podman-containers.nix` guards separately). A path baked in at build time therefore fails. When the Orca check was written, changing the argument to a hardcoded `/run/user/1000` turned the check red.
- **General rule.** Any tool that keeps a persistent per-user namespace holder is at risk here: rootless Podman's pause process, and anything else that later processes join. If a sandboxed client starts it first, host-side users of it break later. Before you believe a "file missing" error from such a tool, find the holder's PID and check `/proc/<pid>/root` (for example `/proc/<pid>/root/etc/static`), `/proc/<pid>/uid_map`, and `/proc/<pid>/environ`. Check them before you change host configuration.
- **Checking host files from a sandboxed shell.** Use `systemd-run --user --wait --pipe --quiet /run/current-system/sw/bin/sh -c '...'` to see the host's view.

## Related Issues

- Issue #121 reported the symptoms and proposed host-side fixes that were already in place.
- Issue #62 added the Testcontainers and Podman session variables (`DOCKER_HOST`) that the sandbox's `CONTAINER_HOST` now mirrors.
- [Orca rejects skill files hardlinked by the Nix store optimiser](orca-rejects-hardlinked-nix-store-skill-files.md) is another Orca packaging trap in `packages/orca.nix`'s neighbourhood.
- [T3 Code's Antigravity ACP server finds no CA bundle on NixOS](t3code-antigravity-acp-openssl-missing-ca-bundle-hangs-sessions.md) is another `extraBwrapArgs` fix in the same `packages/t3code.nix` wrapper.
- [A check that reads an option value passes when the option is disabled or renamed](../best-practices/nix-check-reads-option-value-not-materialized-output.md) is why the regression check reads the materialized launcher.
