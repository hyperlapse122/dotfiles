# Antigravity sidecar decommission checklist (operator-run, not automated)

> **Label:** Antigravity sidecar decommission checklist. This document is manual
> operator guidance for hosts that previously applied the managed sidecar.
> Chezmoi executes none of it: the removal is source-only plus a `.chezmoiremove`
> prune, apply never stops a live service, and no teardown script exists or may be
> added.

## 1. Stop before the first apply

Stop and disable the service before running the first apply. The apply prunes
the unit's `ExecStart` target and the LaunchAgent's program while
`Restart=on-failure` and `KeepAlive=true` are live. See
`docs/decommission/ydotool.md` for the full analysis.

Linux:

```sh
systemctl --user disable --now antigravity-sidecar.service
```

macOS:

```sh
launchctl bootout "gui/$(id -u)/app.dotfiles.antigravity-sidecar"
```

Ignore "No such process" if the agent is not loaded.

## 2. Apply

Run `chezmoi apply` from this repository checkout.

Chezmoi deletes the managed sources and prunes the deployed sidecar paths.
It also removes `~/.omp/agent/models.yml` if the file names `127.0.0.1:45123`.

## 3. Clear the omp model cache

1. Exit running omp sessions.
2. Back up `~/.omp/agent/models.db`:

```sh
cp ~/.omp/agent/models.db ~/.omp/agent/models.db.bak
```

3. Delete cached model entries:

```sh
sqlite3 ~/.omp/agent/models.db "delete from model_cache where provider_id='google-antigravity'"
```

4. Restart each session with `omp --resume <session-id>`.

omp refetches the model list on the next start.

## 4. Verify

Confirm that no process listens on `127.0.0.1:45123`.

- Linux: `ss -ltnp`
- macOS: `lsof -nP -iTCP:45123 -sTCP:LISTEN`

Confirm that every deployed sidecar path is missing:

- `~/.config/systemd/user/antigravity-sidecar.service`
- `~/.config/systemd/user/default.target.wants/antigravity-sidecar.service`
- `~/Library/LaunchAgents/app.dotfiles.antigravity-sidecar.plist`
- `~/.local/bin/antigravity-sidecar`
- `~/.local/lib/commands/current/antigravity-sidecar`
- `~/.local/lib/commands/store/antigravity-sidecar`
- `~/.local/lib/commands/quarantine/antigravity-sidecar`
- `~/.local/share/chezmoi-commands/incomplete/antigravity-sidecar`
- `~/.local/state/dotfiles-antigravity-sidecar`

Confirm that `~/.omp/agent/models.yml` is missing or operator-owned without `127.0.0.1:45123`.

Confirm that the model cache contains no proxy endpoint references:

```sh
sqlite3 ~/.omp/agent/models.db "select count(*) from model_cache where instr(models,'45123')>0"
```

The query must print `0`.

## 5. Recover a host that applied first

If `chezmoi apply` ran before stopping the service, run the stop commands after the apply.

Linux:

```sh
systemctl --user disable --now antigravity-sidecar.service
systemctl --user reset-failed antigravity-sidecar.service
```

macOS:

```sh
launchctl bootout "gui/$(id -u)/app.dotfiles.antigravity-sidecar"
```

The stop commands work after the unit files are gone.

On a lingering Linux host, this recovery stop is required because the process survives logout.
On macOS and on Linux hosts without lingering, the process ends at the next logout because nothing starts the sidecar again.

## 6. Confirm direct routing

Send one `google-antigravity/*` request from omp with the sidecar stopped.
Confirm that omp connects directly to the provider endpoint.
An upstream quota error must surface as a failure.
