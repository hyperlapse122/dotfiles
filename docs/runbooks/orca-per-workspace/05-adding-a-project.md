# 05 -- Adding a project

Orca reads `environmentRecipes` from the target project's own `orca.yaml`, in
that project's PRIMARY checkout. The scripts therefore cannot live in this
repository and be referenced by path from another project -- which is why the
lifecycle ships as the `orca-worker` command instead.

## 1. Have the command installed

`orca-worker` is a chezmoi-managed command unit (`.chezmoidata/commands.yaml`),
deployed to `~/.local/bin/orca-worker` by an ordinary apply. Check:

```sh
command -v orca-worker
```

## 2. Add a wrapper to the project

```sh
mkdir -p scripts/orca-vm
cat > scripts/orca-vm/orca-worker <<'SH'
#!/usr/bin/env bash
exec "$HOME/.local/bin/orca-worker" "$@"
SH
chmod +x scripts/orca-vm/orca-worker
```

Two lines, and they exist for `orca vm recipe doctor`. Doctor takes the first
token of the command string and checks it only when it starts with `./`: an
absolute path or a bare `PATH` name returns early with a warning and is never
checked for existence at all. So pointing the recipe straight at `orca-worker`
still leaves doctor green -- while losing the only static validation it offers.
The wrapper keeps one implementation in this repository and gives doctor a path it
can actually check.

## 3. Wire `orca.yaml`

```yaml
environmentRecipes:
  - id: orca-k3s
    name: k3s worker
    create: ./scripts/orca-vm/orca-worker create
    suspend: ./scripts/orca-vm/orca-worker suspend
    resume: ./scripts/orca-vm/orca-worker resume
    destroy: ./scripts/orca-vm/orca-worker destroy
```

## 4. Commit it to the primary branch

The workspace composer reads `environmentRecipes` from the project's primary
checkout of `orca.yaml`, not from a feature branch or a worktree. A recipe added
only on a branch does not appear in the workspace picker, even though
`doctor` and `--provision` validate it from the working copy on any branch. This
surprises everyone once; it is the single most common "the recipe does not show
up" cause.

## What the workspace gets

- SSH as `worker`, authenticated by the desktop's 1Password SSH agent. The
  emitted target sets `identityAgent` explicitly rather than relying on the
  `Host *` match in `~/.ssh/config`, so the recipe stays correct if that config
  changes.
- `projectRoot` is `/home/worker/workspace`. Orca connects over its SSH relay and
  imports the repository itself; the script does not clone.
- `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` already exported in the login
  shell and in `~/.bashrc`, so both an interactive session and
  `ssh worker <command>` see them.
- Project `op://` references resolvable through Connect, so `op inject`, `op run`
  and `op read` work in `mise` tasks -- including the ones that need 1Password
  desktop approval on a workstation and therefore run BETTER in a worker.

## Per-project knobs

Set these in the project's `orca.yaml` command line or the environment if a
project needs to differ:

| Variable | Purpose |
|---|---|
| `ORCA_WORKER_KUBECONFIG` | a different cluster |
| `ORCA_WORKER_CONNECTION` | force `tailnet` or `nodeport` addressing |
| `ORCA_WORKER_READY_TIMEOUT` | a slower first image pull |
| `ORCA_WORKER_PROJECT_ROOT` | a different checkout path inside the worker |
