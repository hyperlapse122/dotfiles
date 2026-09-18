# @h82/ce-overlay-rebase

Rebase state transitions, dispatch decision, and failure classifier for Compound Engineering (CE) overlays.

## Overview

This package implements pure decision logic and marker state management for the Compound Engineering overlay rebase workflow (issue #526):
- **Marker state machine**: validates schema and handles state transitions (`idle`, `deferred`, `escalated`, `blocked-config`, `awaiting-review`). A target is a stable release tag, `compound-engineering-v<major>.<minor>.<patch>`. Prerelease and build-metadata tags are invalid.
- **Dispatch decision**: pure function deciding whether the lock job or workflow should `skip`, `dispatch`, or `close-then-dispatch`. An `awaiting-review` marker skips while no open pull request targets the resolved tag, so a pull request the owner closed does not trigger another rebase. A manual workflow run starts the rebase again.
- **Failure classifier**: classifies workflow step conclusions and execution files into closed failure classes (`outage`, `quota`, `genuine`, `unknown`, `configuration`). For a `claude-code-action` transcript (a JSON array of messages) it reads only the last `result` entry. For a single JSON object it reads `status`, `message`, `subtype`, `error`, and `result`. Tool results and other transcript content never affect the class.
- **CLI**: JSON-in / JSON-out interface callable from shell scripts and CI.

## CLI

`ce-overlay-rebase <command> [options] [file]` reads JSON from `file` or standard input.

| Command | Input | Result |
| --- | --- | --- |
| `validate-marker` | marker JSON, bare or wrapped in `ceOverlayRebase` | exit 0 and `{"valid": true}`, or exit 1 with the errors on standard error |
| `write-marker [--out <path>]` | marker JSON | validated, wrapped marker document |
| `decide` | dispatch decision input | decision JSON |
| `classify` | classifier input | `{"failureClass": ...}` |
| `transition` | `{currentMarker, event}` | next marker JSON |
| `validate-class <value>` | one argument | exit 0 when `<value>` is a failure class, otherwise exit 1 with a message on standard error |

`validate-class` is the single place that defines the closed failure-class set for shell callers:

```sh
ce-overlay-rebase validate-class outage   # exit 0
ce-overlay-rebase validate-class nothing  # exit 1
```
