# .github/

GitHub-specific repository configuration. GitHub only reads this directory at
the repository root.

## Layout

| Path | Purpose |
|---|---|
| [`workflows/packages.yml`](workflows/packages.yml) | CI for the [`packages/`](../packages/) Yarn workspace — builds, typechecks, and tests every member on pushes to `main` and on PRs that touch `packages/**`. |

## `workflows/packages.yml`

- **Toolchain via mise.** Node and Yarn are installed by
  [`jdx/mise-action`](https://github.com/jdx/mise-action) from
  [`packages/mise.toml`](../packages/mise.toml) (the action runs with
  `working_directory: packages`). This keeps CI and local development on the
  same pinned versions.
- **Caching.** The action caches the mise tool installs (keyed on the mise
  config); a separate `actions/cache` step caches Yarn 4's global package cache
  at `~/.yarn/berry/cache` (keyed on `packages/yarn.lock`).
- **Steps.** `yarn install --immutable` (the committed lockfile must already be
  up to date), then `yarn turbo run build typecheck test` — Turborepo runs and
  caches each member's tasks.

There is intentionally no bootstrap/dotbot wiring here: workflows are consumed by
GitHub Actions, not symlinked into `$HOME`.

## Adding a workflow

1. Add `workflows/<name>.yml`.
2. Add a row to the layout table above (this directory's hard
   documentation-sync requirement).
3. If the change is repo-structure-visible, update the root
   [`AGENTS.md`](../AGENTS.md) and [`README.md`](../README.md) in the same
   commit.
