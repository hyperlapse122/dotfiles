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
| [`workflows/opencode-plugin-updates.yml`](workflows/opencode-plugin-updates.yml) | Hourly (cron) + manual dispatcher that fans out over a matrix of opencode plugins, calling the reusable `update-opencode-plugin.yml` once per plugin. |
| [`workflows/update-opencode-plugin.yml`](workflows/update-opencode-plugin.yml) | Reusable (`workflow_call`) workflow that compares one plugin's pinned version in [`home/.config/opencode/opencode.json`](../home/.config/opencode/opencode.json) against the latest GitHub release of its upstream repo and opens a PR bumping it. |

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

## `workflows/opencode-plugin-updates.yml` + `workflows/update-opencode-plugin.yml`

Keep the opencode plugins pinned in
[`home/.config/opencode/opencode.json`](../home/.config/opencode/opencode.json)
up to date with their upstream GitHub releases.

- **Dispatcher (`opencode-plugin-updates.yml`).** Runs hourly (`cron: "0 * * * *"`,
  UTC) and on manual `workflow_dispatch`. A single job uses a `matrix` (one entry
  per plugin) to call the reusable workflow with two inputs: the plugin's package
  name *exactly as written in the config `plugin` array* and the GitHub
  `owner/repo` that publishes its releases. **To track a new plugin, add one
  matrix entry — nothing else changes.** `fail-fast: false` keeps one plugin's
  failure from aborting the others.
- **Reusable worker (`update-opencode-plugin.yml`, `workflow_call`).** For one
  plugin: reads the latest release tag via `gh release view` (strips the
  `tag-prefix`, default `v`), reads the currently pinned version from the config,
  and when they differ, bumps the version and opens a PR (assigned to the repo
  owner) on a per-version branch `automation/opencode-plugin/<slug>/<version>`.
  It is idempotent — an existing branch for that exact version short-circuits —
  and it closes superseded automation PRs for the same plugin so only the newest
  bump stays open.
- **Format-preserving bump.** The worker does a literal substitution (Perl
  `\Q..\E`) on the single version token rather than a `jq` rewrite, so the
  config's exact formatting (tabs, key order, spacing) is preserved and the diff
  stays one line. A `jq` pass would reserialize and reformat the whole file.
- **Requirements.** Both workflows declare `contents: write` + `pull-requests: write`.
  The repo setting *Settings → Actions → General → Workflow permissions → Allow
  GitHub Actions to create and approve pull requests* must be enabled for the
  default `GITHUB_TOKEN` to open the PRs. PRs opened by `GITHUB_TOKEN` do not
  trigger further workflow runs.

There is intentionally no bootstrap/dotbot wiring here: workflows are consumed by
GitHub Actions, not symlinked into `$HOME`.

## Adding a workflow

1. Add `workflows/<name>.yml`.
2. Add a row to the layout table above (this directory's hard
   documentation-sync requirement).
3. If the change is repo-structure-visible, update the root
   [`AGENTS.md`](../AGENTS.md) and [`README.md`](../README.md) in the same
   commit.
