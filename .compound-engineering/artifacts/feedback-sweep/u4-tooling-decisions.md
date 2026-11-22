# Tier 2 decisions for project checks

| Issue | Decision |
| --- | --- |
| [#206](https://github.com/hyperlapse122/dotfiles/issues/206) | Adopt `impeccable detect` from the existing `skill-v4.8.0` pin. File detection is offline. Use it before finishing UI work or as a project gate, outside per-edit hooks. |
| [#208](https://github.com/hyperlapse122/dotfiles/issues/208) | Adopt the pinned native `agent-browser` CLI for standalone sessions with separately provisioned Chrome and a disposable profile. T3 Code uses its preview tools. The CLI covers the requested render check, so the optional DevTools MCP is omitted. |
| [#209](https://github.com/hyperlapse122/dotfiles/issues/209) | Adopt the deterministic warnings and opt-in availability checks in `agent-check`. Warnings are advisory. CI fails on a missing dependency or incomplete lookup. Only an owner-approved policy outside the diff can route a name to a registry. |
| [#210](https://github.com/hyperlapse122/dotfiles/issues/210) | Adopt the pinned Context7 CLI and render one `find-docs` entry per shared skill root. Lookup starts anonymously. The owner may run `ctx7 login` or supply `CONTEXT7_API_KEY`. Home Manager installs the CLI and skill without running setup or managing OAuth state. |

Context7 receives public library names and sanitized documentation queries.
The packaged lookup uses JSON output to keep it noninteractive. The package
disables usage telemetry.

## Repository checks

- The macOS package checks covered CLI installation and help. The packaged
  `agent-check` covered staged and committed snapshots, local warnings,
  successful and missing registry entries, unavailable registries, private
  routing, and non-registry references.
- Impeccable's Rust engine built with Cargo offline. With network access denied,
  the installed detector identified `overused-font` in a CSS fixture and exited 2.
- A live run from a disposable project verified one dependency each at the
  public npm registry, PyPI, and the Go proxy. The workflow test confirmed that
  CI passes the trusted policy and the correct Git range to `agent-check`.
- The x86_64-linux derivations evaluated locally. Linux package builds and the
  materialized skill-root checks are deferred to CI.

## Native observations

- The pinned `agent-browser` launched the provisioned macOS Chrome with a
  disposable profile, measured zero horizontal overflow on a local page, and
  saved an 800×600 viewport screenshot.
- The rendered `find-docs` ran both lookup commands with the packaged binary in
  a disposable home without credentials or npm on `PATH`. Codex 0.171.0 listed
  one `find-docs` description in that disposable home. The macOS production and
  bootstrap configurations expose the same skill at all four managed roots.
