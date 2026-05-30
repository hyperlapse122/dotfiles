# .github/

GitHub-specific repository configuration. GitHub only reads this directory at
the repository root.

> **Why this file is not `README.md`.** GitHub gives `.github/README.md`
> precedence over the root `README.md` for the repository landing page. A readme
> here would shadow the top-level [`README.md`](../README.md), so this directory
> is documented in `WORKFLOWS.md` instead (GitHub does not treat that filename as
> a profile readme). See the root [`AGENTS.md`](../AGENTS.md).

## Layout

| Path | Purpose |
|---|---|
| [`workflows/packages.yml`](workflows/packages.yml) | CI for the [`packages/`](../packages/) Yarn workspace — builds, typechecks, and tests every member on pushes to `main` and on PRs that touch `packages/**`. |
| [`workflows/lint.yml`](workflows/lint.yml) | CI for the [`packages/`](../packages/) Yarn workspace — ESLint lint + Prettier format-check on every member, on the same triggers. Split from `packages.yml` so a style regression is reported independently of a build/test failure. |

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

## `workflows/lint.yml`

- **Same toolchain + caching as `packages.yml`.** mise installs Node + Yarn from
  [`packages/mise.toml`](../packages/mise.toml); the mise tool installs and Yarn 4's
  global cache (`~/.yarn/berry/cache`) are both cached.
- **Steps.** `yarn install --immutable`, then `yarn turbo run lint format:check` —
  ESLint (per-member `eslint.config.mjs`) plus Prettier `--check`. Neither task
  `dependsOn ^build` in `turbo.json`, so no build runs.
- **Why a separate workflow.** Lint/format checks are split from build/test so a
  style regression surfaces independently. There is intentionally **no Biome** —
  the workspace uses ESLint for linting and Prettier for formatting.

There is intentionally no bootstrap/dotbot wiring here: workflows are consumed by
GitHub Actions, not symlinked into `$HOME`.

## Adding a workflow

1. Add `workflows/<name>.yml`.
2. Add a row to the layout table above (this directory's hard
   documentation-sync requirement).
3. If the change is repo-structure-visible, update the root
   [`AGENTS.md`](../AGENTS.md) and [`README.md`](../README.md) in the same
   commit.
