# Coordinator wait and Antigravity pin review

## Scope and outcome

Review covered the 37-file branch diff from `2137baca15502658c9a0068aebc7a810d35f0255`, including simplification edits.
Both explicit plans' requirements and implementation units are met by the source and the runtime evidence in [the preflight record](2026-09-13-coordinator-wait-preflight.md).
No live deployment occurred.

The review produced two validated changes, applied in `2b98823`:

- Share stable-release validation between exact-tag and prefix selection. Preserve exact-tag diagnostics and add a malformed prefix-list regression.
- Keep package tests independent of Bash and the repository CI layout. The repository test now runs the real resolver and CLI against absent and malformed digest fixtures, then verifies rejection through the digest gate.

A third proposal would merge per-job setup into a composite action. The validator rejected it because the [CI split plan](../plans/2026-09-02-1523-refactor-ci-split-agent-integration-job-plan.md) explicitly selected independent job setup.
No actionable review finding remains unapplied.

## Coverage limits

Ten review lenses were dispatched through Orca. Claude adversarial, corrected full-scope API contract, agent-native, and learnings reviews completed.
Correctness, security, testing, project standards, maintainability, and reliability exceeded their ten-minute deadlines and were stopped and released.
Security and maintainability saved usable artifacts before termination. The coordinator supplemented incomplete lenses with direct inspection, not independent corroboration.

Codex launches reported requested and effective `gpt-5.6-luna` with `max` effort.
The Claude receipt established the provider but not the model or effort. It was not used for confidence promotion.
One fresh Codex validator checked all three candidates. It accepted two and rejected one.
All owned review terminals were released. The first API dispatch transferred its terminal to the corrected dispatch, which was then released.

The final checks passed 510 package tests, package formatting/lint/type checks, the digest regression, ShellCheck, CI wiring, and diff whitespace checks.
Unchanged packages used the existing task cache. The changed release-lock suite ran 296 tests.
Browser validation is not applicable. This branch changes no web routes or pages.

## Official archive verification

All four official 1.1.28 archives matched the SHA-256 values already recorded in the release lock.
`tar -tzf` reported the single member `antigravity` for each archive, matching the managed external's extraction path.

| Platform | Official asset | SHA-256 |
| --- | --- | --- |
| linux-amd64 | agy_cli_linux_x64.tar.gz | `074ff4f732a750ad727aeed5fc82ed34b1fb72fda2a6ceba6c8e652ffd0a94b0` |
| linux-arm64 | agy_cli_linux_arm64.tar.gz | `789420d2937393498eb158c4af8321d78c387e31c861db0c79627879509aa8a8` |
| darwin-amd64 | agy_cli_mac_x64.tar.gz | `629887c5baf30c9c1c130a5d3d9fdfebdf0b67ffd45f822d771c0abfb69e405b` |
| darwin-arm64 | agy_cli_mac_arm64.tar.gz | `8f642cffce8bc14aa3e49d1a75780bb2bd99fe7a3016389627476d9e3ec911eb` |

Only Linux amd64 was executed. Linux arm64 and both macOS targets remain artifact-verified only.
The downloads were inspected in temporary directories, not installed.

## Advisory limits

Native interpretation of `ask` for an existing allow grant or a non-command tool was not separately integration-tested.
The isolated command lifecycle preserved native approval and completed successfully.
The updater check exercises the exported zshenv leaf, not the complete login chain.
Existing processes need a fresh inherited environment after deployment.
Previously staged updater behavior and untested runtime platforms are not covered by the fresh-session evidence.
These are verification limits, not claims of observed failures.
