# scripts/

Helpers shared by `install.sh` and `install.ps1`.

## Current scripts

| Script | Platform | Called by | Purpose |
|---|---|---|---|
| `install-linux-system-config.sh` | Linux only | `install.linux.yaml` `shell:` step | Recursively discovers files in `system/linux/etc/` and runs `sudo install -D -m 644` to their absolute paths |

## Script parity rule

Every helper here ships in **both** forms:

| Surface | Extension | Targets |
|---|---|---|
| POSIX | `.sh` (`#!/usr/bin/env bash`) | macOS + Linux |
| PowerShell | `.ps1` | Windows |

Adding `foo.sh` without `foo.ps1` is a regression. If a helper is meaningless on one platform, the parity script SHOULD exit with a clear error, NOT silently no-op.

Exception: helpers that are inherently single-platform (e.g. wrappers around Linux-only `pacman`) MAY skip parity — document the reason in a header comment in the script itself.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
