# @h82/ce-overlay-rebase

Rebase state transitions, dispatch decision, and failure classifier for Compound Engineering (CE) overlays.

## Overview

This package implements pure decision logic and marker state management for the Compound Engineering overlay rebase workflow (issue #526):
- **Marker state machine**: validates schema and handles state transitions (`idle`, `deferred`, `escalated`, `blocked-config`, `awaiting-review`).
- **Dispatch decision**: pure function deciding whether the lock job or workflow should `skip`, `dispatch`, or `close-then-dispatch`.
- **Failure classifier**: classifies workflow step conclusions and execution files into closed failure classes (`outage`, `quota`, `genuine`, `unknown`, `configuration`).
- **CLI**: JSON-in / JSON-out interface callable from shell scripts and CI.
