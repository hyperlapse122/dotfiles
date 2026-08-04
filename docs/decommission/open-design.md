# Open Design decommission checklist (operator-run, not automated)

> **Label:** Open Design decommission checklist. This document is manual
> operator guidance for hosts that previously applied the managed integration.
> Chezmoi executes none of it: the removal is source-only, apply never stops a
> live service, deletes the generated checkout, application data, or
> credentials, and no teardown script exists or may be added.

Apply the updated source first. Deleting managed sources stops chezmoi from
managing their deployed targets, but leaves the running service, the managed
checkout, application data, and vendor sessions untouched. Work through this
checklist by hand on each previously provisioned Linux host.

## 1. Stop the user service

- `systemctl --user stop open-design.service` (the unit was always shipped
  unenabled and on-demand, so there is nothing to disable)

## 2. Verify nothing still listens

- Confirm no process owns TCP `127.0.0.1:36947` (web) or `127.0.0.1:43909`
  (daemon) — for example `ss -ltnp`. If a listener survives, identify and stop
  it before continuing; never kill a process you cannot attribute to this
  stack.

## 3. Remove deployed definitions and launchers (after the service is down)

Only the files the integration deployed; a missing path is fine.

- `~/.config/systemd/user/open-design.service`, then
  `systemctl --user daemon-reload`.
- `~/.local/bin/open-design`, `~/.local/bin/open-design-desktop`,
  `~/.local/libexec/open-design/`, and
  `~/.local/share/applications/open-design.desktop`.
- The root-owned system-sleep hook `/etc/systemd/system-sleep/open-design.sh`
  is reclaimed automatically by the system installer manifest on the next
  apply; remove it by hand only if the host will not apply again.
- Managed agent configs (Claude/Codex dotagents and omp) lose the
  `open-design` MCP server on the next apply; no manual edit is needed.

## 4. Managed checkout and application data (optional, explicit opt-in)

- The execution-only checkout root `~/.local/share/open-design/` may be
  deleted once the service is down; it is disposable state.
- Persistent application data lives at `~/.od` (`OD_DATA_DIR`) and holds
  Open Design projects and vendor session material. Retain it unless you are
  certain nothing needs it; deletion is irreversible.
- Runtime IPC under `$XDG_RUNTIME_DIR/open-design/` is tmpfs and disappears
  with the session; no action needed.
- The developer checkout `~/src/github.com/nexu-io/open-design` was never
  managed by this repository; leave it alone unless you decide separately.

## 5. Credential boundary — no chezmoi-managed credentials exist

- Chezmoi never stored Open Design credentials: the source carried no `op://`
  references for it, and no 1Password items belong to this integration.
- Vendor-native OAuth sessions live only under `~/.od`. End those sessions
  through each provider's own flows if desired; do not read, print, or copy
  tokens out of the data directory.
