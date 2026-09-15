# omp Orca extension

This package injects Orca instructions through omp's `before_agent_start` event.
It calls the managed orchestration hook for the current role before each model
call and replaces only its own system-prompt block. Hook failures remove stale
instructions and report a diagnostic. The hook process has an eight-second
deadline and a two-MiB output limit.

The phase-60 build stages `dotfiles-orca.js`. Chezmoi links it into
`~/.omp/agent/extensions/`. No credentials are required by this extension.

Run `vp test`, `vp run typecheck`, and `vp run build` in this directory.
See [deployment and live checks](../../docs/operations/omp-transition.md).
