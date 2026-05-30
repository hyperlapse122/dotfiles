# packages/

The **`@h82/dotfiles` Yarn Berry monorepo** — a single Yarn workspace whose root
is this directory. It holds the repo's TypeScript/JavaScript library packages.

- **Workspace root**: [`package.json`](package.json) is the private
  `@h82/dotfiles` root with `"workspaces": ["*"]`. Each subdirectory containing
  a `package.json` is a member.
- **The root is `packages/`, not the repo root.** This is deliberate: there is
  no `package.json`/`yarn.lock`/`.yarn/` at `~/dotfiles`, so `cd ~/dotfiles`
  stays a plain checkout, while `cd ~/dotfiles/packages` is the Yarn project. A
  repo-root manifest would otherwise turn the whole checkout into a Yarn project
  (the user-global `~/.yarnrc.yml` applies repo-wide).

## What this is NOT

- **Built at bootstrap, never installed.** Unlike [`../crates/`](../crates/)
  (whose Rust binaries are `cargo install`'d into `~/.local/bin`), a library
  here ships nothing to install and dotbot links nothing from `packages/`. The
  Linux bootstrap ([`../install.linux.yaml`](../install.linux.yaml)) does run
  `yarn build` (turbo) in place via `mise -C packages exec` (soft-skipping when
  mise is absent), so the workspace is built after a checkout; macOS/Windows
  bootstrap do not. Nothing is symlinked or copied out.
- **Not published.** Members are `private: true`; the `@h82/` scope is a naming
  namespace, not a registry target.

## Members

| Path | Package | Purpose |
|---|---|---|
| [`mxm4-haptic/`](mxm4-haptic/) | `@h82/mxm4-haptic` | Node/Bun client for the `mxm4-hapticd` daemon — sends MX Master 4 haptic waveforms over the daemon's AF_UNIX socket. Mirrors the portable client surface of [`../crates/mxm4-haptic/src/lib.rs`](../crates/mxm4-haptic/src/lib.rs). |
| [`opencode-mxm4-haptic/`](opencode-mxm4-haptic/) | `@h82/opencode-mxm4-haptic` | OpenCode plugin that pulses MX Master 4 haptics on OpenCode events (e.g. `session.idle` → `COMPLETED`). Forwards waveforms to the `mxm4-hapticd` daemon via a bundled `@h82/mxm4-haptic`. |

## Conventions

- **Package manager: Yarn Berry** (the repo-wide preferred manager). The
  user-global `~/.yarnrc.yml` hardening applies to the whole workspace: exact
  version pinning (no `^`/`~`/ranges), a 1-week dependency cooldown gate
  (`npmMinimalAgeGate`), and disabled lifecycle scripts (`enableScripts: false`).
  Do not relax these. The workspace-root [`.yarnrc.yml`](.yarnrc.yml) overrides
  only `nodeLinker: node-modules` (so plain `tsc`/`node --test` resolve a normal
  `node_modules/` tree instead of PnP); everything else cascades.
- **One lockfile**: the workspace-root `packages/yarn.lock` is the only lockfile
  and is **tracked** (lockfile convention, like the Rust `Cargo.lock` under
  `crates/`). `node_modules/` hoists to `packages/node_modules/`. There are no
  per-member lockfiles or `node_modules/`. Per-member `dist/` build output,
  `packages/node_modules/`, and `packages/.yarn/` are git-ignored (scoped
  patterns in the root `.gitignore`).
- **First install gotcha**: the user-global `enableImmutableInstalls: true`
  makes the very first `yarn install` (which must generate `yarn.lock`) fail.
  Use `yarn add <pkg>@<exact>` (a mutating command) or
  `yarn install --no-immutable` for the initial lockfile; subsequent
  `yarn install --immutable` runs are clean.

## Working in the workspace

Tasks are orchestrated by [Turborepo](https://turborepo.com)
([`turbo.json`](turbo.json) defines `build`, `typecheck`, `test`, `lint`,
`format`, and `format:check`). The workspace-root scripts delegate to
`turbo run …`:

```sh
cd packages
yarn install --immutable   # restore deps (clean once yarn.lock exists)
yarn build                 # turbo run build        (across all members, cached)
yarn typecheck             # turbo run typecheck
yarn test                  # turbo run test
yarn lint                  # turbo run lint         (ESLint, per-member config)
yarn format                # turbo run format       (Prettier --write)
yarn format:check          # turbo run format:check (Prettier --check; CI uses this)

# or target a single member directly:
yarn workspace @h82/mxm4-haptic build
```

`build` outputs `dist/**`; `typecheck` and `test` `dependsOn` `^build`;
`lint`/`format`/`format:check` have no deps (ESLint/Prettier read source
directly). `format` is `cache: false` because it writes. Turbo's caches
(`packages/.turbo/`, `packages/*/.turbo/`) are git-ignored.

## Lint + format

ESLint does the **linting**, Prettier does the **formatting** — there is
intentionally **no Biome**. Configuration is **per member** (no root-level lint
config):

- `eslint.config.mjs` — flat config: `@eslint/js` + `typescript-eslint`
  recommended, `@typescript-eslint/no-unused-vars` tuned to allow `_`-prefixed
  identifiers, and `eslint-config-prettier` appended last so ESLint never fights
  Prettier over style.
- `.prettierrc.json` — `printWidth: 100`.
- `.prettierignore` — excludes `dist/`, `.turbo/`, `node_modules/`, `*.json`,
  `*.md` so Prettier only touches `.ts`/`.mjs` source.

CI runs `lint` + `format:check` via
[`../.github/workflows/lint.yml`](../.github/workflows/lint.yml), separate from
the build/test workflow.

### Editor (VS Code)

[`.vscode/`](.vscode/) is scoped to this workspace on purpose — it lives under
`packages/`, **not** the repo root, so ESLint + Prettier activate only when you
open `packages/` as the folder and never affect the rest of the dotfiles
checkout. [`settings.json`](.vscode/settings.json) makes Prettier the on-save
formatter for TS/JS (respecting each member's `.prettierignore`), enables ESLint
flat config with `eslint.workingDirectories: [{ "mode": "auto" }]` so per-member
configs resolve, and applies `source.fixAll.eslint` on save;
[`extensions.json`](.vscode/extensions.json) recommends the ESLint + Prettier
extensions.

## Adding a new package

1. `mkdir packages/<name>` and add `package.json` (`@h82/<name>`,
   `private: true`, `"type": "module"`). The `"workspaces": ["*"]` glob picks it
   up automatically. Reference sibling packages with the `workspace:*` protocol.
2. Pin every dependency to an exact, cooldown-valid (≥7 days old) version. Run
   `yarn install` from `packages/` to update the single root `yarn.lock`.
3. Give the member its own lint/format setup (per-member, no root config): add
   `eslint`, `@eslint/js`, `typescript-eslint`, `eslint-config-prettier`, and
   `prettier` as exact-pinned devDeps, an `eslint.config.mjs`, a
   `.prettierrc.json`, a `.prettierignore`, and `lint`/`format`/`format:check`
   scripts. Copy an existing member's config as the template.
4. Document the package in its own `README.md` and add a row to the members
   table above.
5. Update the root [`AGENTS.md`](../AGENTS.md) Layout block and
   [`README.md`](../README.md) repo-structure table in the **same commit** (the
   repo's hard documentation-sync rule).
