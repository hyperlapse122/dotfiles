# CLIProxyAPI and CPA-Manager-Plus decommission checklist (operator-run, not automated)

> **Label:** CLIProxyAPI decommission checklist. This document is manual
> operator guidance for hosts that previously applied the managed integration.
> Chezmoi executes none of it: the removal is source-only, apply never stops a
> live service, deletes runtime state, or reads provider credentials, and no
> teardown script exists or may be added.

Apply the updated source first. Deleting managed sources stops chezmoi from
managing their deployed targets, but leaves running services, the runtime data
root, and credentials untouched. Work through this checklist by hand on each
previously provisioned Linux or macOS host.

## 1. Stop and disable the services

Linux (Podman quadlets, per user that ran them):

- `systemctl --user stop cpa-manager-plus.service cli-proxy-api.service`
- `systemctl --user disable cpa-manager-plus.service cli-proxy-api.service`

macOS (launchd agent):

- `launchctl bootout "gui/$(id -u)/dev.h82.cli-proxy-api"` (ignore
  "No such process" if the agent is not loaded)

## 2. Verify nothing still listens

- Confirm no process owns TCP `127.0.0.1:8317` (proxy) or `127.0.0.1:18317`
  (management panel) — for example `ss -ltnp` on Linux or
  `lsof -nP -iTCP:8317 -iTCP:18317 -sTCP:LISTEN` on macOS. If a listener
  survives, identify and stop it before continuing; never kill a process you
  cannot attribute to this stack.

## 3. Remove deployed definitions and launchers (after the services are down)

Only the files the integration deployed; a missing path is fine.

- Linux: `~/.config/containers/systemd/cli-proxy-api.container`,
  `~/.config/containers/systemd/cli-proxy-api.network`,
  `~/.config/containers/systemd/cpa-manager-plus.container`, then
  `systemctl --user daemon-reload`. Legacy pre-quadlet residue, if present:
  `~/.config/systemd/user/cli-proxy-api.service`.
- macOS: `~/Library/LaunchAgents/dev.h82.cli-proxy-api.plist`,
  `~/.local/libexec/cli-proxy-api-launch`, `~/.local/bin/cli-proxy-api`.
- The root-owned system-sleep hook `/etc/systemd/system-sleep/cli-proxy-api.sh`
  is reclaimed automatically by the system installer manifest on the next
  apply; remove it by hand only if the host will not apply again.

## 4. Container images and state (optional, explicit opt-in)

- The pulled OCI images (`docker.io/eceasy/cli-proxy-api`,
  `ghcr.io/seakee/cpa-manager-plus`) may be pruned with
  `podman image rm` once no container references them.
- The runtime data root `~/.local/share/cli-proxy-api/` holds the seeded
  runtime config (bcrypt-hashed management key), CPAMP SQLite state and
  credential files, and provider auth material. Retain it unless you are
  certain nothing needs it; deletion is irreversible.

## 5. Credential boundary — never read or delete provider credentials

- Do not read, print, copy, or delete anything under the provider auth
  directory (`~/.local/share/cli-proxy-api/auth/`) unless you have separately
  decided to end those provider sessions. Handle provider sign-out through
  the provider's own flows, per host.
- The 1Password items `op://Private/CLI Proxy API/password` and
  `op://Private/CPA Manager Plus/password` stay in 1Password, operator-owned;
  delete them only as a separate explicit action.
- Chezmoi never stored plaintext credentials: source carried only the `op://`
  references above, and runtime secrets lived exclusively under the data root.
