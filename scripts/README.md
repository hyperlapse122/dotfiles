# scripts/

Helpers shared by `install.sh` and `install.ps1`. Currently empty — populate as the install scripts grow.

## Script parity rule

Every helper here ships in **both** forms:

| Surface | Extension | Targets |
|---|---|---|
| POSIX | `.sh` (`#!/usr/bin/env bash`) | macOS + Linux |
| PowerShell | `.ps1` | Windows |

Adding `foo.sh` without `foo.ps1` is a regression. If a helper is meaningless on one platform, the parity script SHOULD exit with a clear error, NOT silently no-op.

Exception: helpers that are inherently single-platform (e.g. wrappers around Linux-only `pacman`) MAY skip parity — document the reason in a header comment in the script itself.

See [`../AGENTS.md`](../AGENTS.md) for the repo-wide contract.
