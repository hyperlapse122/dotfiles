# @h82/command-reconcile

Serialized versioned command reconciler and safe pruner for repository-owned commands.

## Purpose

- Reconciles repository-managed public command links in `~/.local/bin` through atomic unit current symlinks in `~/.local/lib/commands/current/`.
- Manages completed immutable stores under `~/.local/lib/commands/store/`.
- Provides proof-classified live process root scanning (Linux procfs, macOS lsof) and safe quarantine-based pruning of older native versions without breaking active processes.
- Maintains versioned state under `~/.local/state/chezmoi-command-reconcile/state.json` (`command-reconcile/v1`) serialized with a store-wide exclusive lease.

## Commands

```sh
command-reconcile activate-unit --manifest <path|json> --unit <id> [--home <path>]
command-reconcile reconcile-all --manifest <path|json> [--home <path>] [--prune]
```
