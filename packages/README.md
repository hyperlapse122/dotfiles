# packages/

The **`@h82/dotfiles` Bun workspace** — a single Bun workspace whose root is
this directory, driven by [Vite+](https://viteplus.dev) (the `vp` CLI). It holds
the repo's TypeScript/JavaScript library packages.

- **Workspace root**: [`package.json`](package.json) is the private
  `@h82/dotfiles` root with `"workspaces": ["*"]`. Each subdirectory containing
  a `package.json` is a member. Shared toolchain config lives in the root
  [`vite.config.ts`](vite.config.ts).
- **The root is `packages/`, not the repo root.** This is deliberate: there is
  no `package.json`/`bun.lock` at `~/dotfiles`, so `cd ~/dotfiles` stays a plain
  checkout, while `cd ~/dotfiles/packages` is the Bun project. A repo-root
  manifest would otherwise turn the whole checkout into a Bun project.

## What this is NOT

- **Built on apply, not directly deployed.** Unlike the other files here which chezmoi deploys to `$HOME`, `packages/` and `crates/` are source-only trees. They are excluded from deployment via `.chezmoiignore`. Instead, they are built on apply by the `.chezmoiscripts/60-build/` run_onchange scripts. OpenCode plugins are symlinked into `~/.config/opencode/plugins/`; standalone CLIs are installed as regular executables in `~/.local/bin/`.
- **Not published.** Members are `private: true`; the `@h82/` scope is a naming
  namespace, not a registry target.

## Members

| Path | Package | Purpose |
|---|---|---|
| [`figma-auth/`](figma-auth/) | `@h82/figma-auth` | Standalone `figma-auth <opencode\|pi>` CLI. It runs a fresh Figma MCP OAuth/PKCE/DCR flow on demand and atomically writes the selected harness's private native credential format; apply only compiles and installs it. |
| [`mxm4-haptic/`](mxm4-haptic/) | `@h82/mxm4-haptic` | Node/Bun client for the `mxm4-hapticd` daemon — sends MX Master 4 haptic waveforms over the daemon's AF_UNIX socket. Mirrors the portable client surface of [`../crates/mxm4-haptic/src/lib.rs`](../crates/mxm4-haptic/src/lib.rs). |
| [`opencode-mxm4-haptic/`](opencode-mxm4-haptic/) | `@h82/opencode-mxm4-haptic` | OpenCode plugin that pulses MX Master 4 haptics on OpenCode events (e.g. `session.idle` → `COMPLETED`). Forwards waveforms to the `mxm4-hapticd` daemon via a bundled `@h82/mxm4-haptic`. |
| [`opencode-playwright-cli-session-injection/`](opencode-playwright-cli-session-injection/) | `@h82/opencode-playwright-cli-session-injection` | OpenCode plugin that sets `PLAYWRIGHT_CLI_SESSION = opencode-<hash8>` (first 8 hex chars of the SHA-1 of the raw `cwd` string) via the `shell.env` hook, giving each project a stable, isolated `playwright-cli` browser session. Cross-platform. |
| [`opencode-scratch-guard/`](opencode-scratch-guard/) | `@h82/opencode-scratch-guard` | OpenCode plugin that enforces the `AGENTS.md` temp-file policy: injects a per-user scratch dir as `$TMPDIR` via `shell.env`, and denies the shared system temp (`/tmp`, `/var/tmp`, `/dev/shm`) for `bash`/`write`/`edit`/`read` via `tool.execute.before`. Mode via `OPENCODE_SCRATCH_GUARD` (`enforce`/`warn`/`off`). Cross-platform. |

## Toolchain: Vite+

The workspace uses **[Vite+](https://viteplus.dev)** (`vp`), a unified toolchain
that replaces the previous split of Turborepo + tsdown + `bun test` + ESLint +
Prettier. A single dependency — `vite-plus`, pinned through the root
[`package.json`](package.json) `catalog` — provides:

- **`vp pack`** — library builds (tsdown/Rolldown under the hood), configured per
  member in the `pack` block of that member's `vite.config.ts`.
- **`vp test`** — tests on **Vitest**; test files import from `vite-plus/test`.
- **`vp lint`** (**Oxlint**) and **`vp fmt`** (**Oxfmt**) — configured in the
  `lint` / `fmt` blocks of the root [`vite.config.ts`](vite.config.ts).
- **`vp check`** — format + lint + type-check in one pass (the recommended
  validation loop).
- **`vp run`** — the monorepo task runner (replaces Turborepo), with caching and
  workspace-dependency ordering.

`vp` itself is the global `viteplus` mise tool; Bun stays the package manager
(`vp install` / `vp add` delegate to it).

## Conventions

- **Package manager: Bun** (the repo-wide preferred manager), driven through
  Vite+ (`vp install`). The user-global `~/.bunfig.toml` hardening applies to the
  whole workspace: exact version pinning (`exact = true`), a 1-week dependency
  cooldown gate (`minimumReleaseAge = 604800`), and disabled lifecycle scripts
  (`ignoreScripts = true`). Do not relax these. The workspace-local
  [`bunfig.toml`](bunfig.toml) mirrors that hardening and additionally sets
  `linker = "hoisted"` so Vitest resolves to a single copy (see
  [Lint + format + test](#lint--format--test)). The workspace-root
  [`package.json`](package.json) pins `"packageManager": "bun@1.3.14"`, so the
  workspace uses a single known Bun version regardless of what is installed
  globally.
- **One lockfile**: the workspace-root `packages/bun.lock` is the only lockfile
  and is **tracked** (lockfile convention, like the Rust `Cargo.lock` under
  `crates/`). `node_modules/` hoists to `packages/node_modules/`. There are no
  per-member lockfiles or `node_modules/`. Per-member `dist/` build output,
  `packages/node_modules/`, and Vite+ Task caches (`packages/.turbo/`) are
  git-ignored (scoped patterns in the root `.gitignore`).
- **First install**: `vp install --frozen-lockfile` restores dependencies once
  `bun.lock` exists. To add a dependency, edit `package.json` to an exact,
  cooldown-valid version and run `vp install` from `packages/` so the lockfile
  updates.

## Working in the workspace

Tasks are orchestrated by **Vite+ Task**: each member's `vite.config.ts`
`run.tasks` defines `build`, `typecheck`, and `test`, each with `dependsOn` on
every workspace dependency's `build` (the old Turborepo `^build`). Run them
across all members with `vp run -r <task>`, or from the workspace root via the
delegating [`package.json`](package.json) scripts:

```sh
cd packages
vp install --frozen-lockfile   # restore deps (clean once bun.lock exists)
vp run -r build                # vp pack across all members, dependency-ordered + cached
vp run -r typecheck            # tsc --noEmit per member
vp run -r test                 # Vitest per member
vp check                       # format + lint + type-check (Oxfmt + Oxlint + tsgolint)
vp lint                        # Oxlint only
vp fmt                         # Oxfmt (write); `vp fmt --check` to verify

# or target a single member directly:
cd packages/mxm4-haptic && vp pack

# figma-auth is a compiled CLI rather than a packed library:
cd packages/figma-auth
bun build --compile ./src/index.ts --outfile ./dist/figma-auth
```

`build` outputs `dist/**`; `typecheck` and `test` build each workspace
dependency first. Vite+ Task caches (`packages/.turbo/`, `packages/*/.turbo/`)
are git-ignored.

`figma-auth` is installed on Linux/macOS by
`run_onchange_after_build-figma-auth.sh.tmpl` at `~/.local/bin/figma-auth` and
is never run during apply. The Figma MCP's headerless OAuth entry comes from
`.chezmoidata/agents.yaml`; invoke `figma-auth opencode` and `figma-auth pi`
manually to seed each harness's native OAuth store. The targets are respectively
`~/.local/share/opencode/mcp-auth.json` and
`~/.pi/agent/mcp-auth/<sha256("figma")[0:16]>.json`; writes are private and
atomic. A soft-skipped build preserves the installed executable and, under
`run_onchange` semantics, retries only after an input change or
`chezmoi apply --force`; the manual compile command above is the non-deploying
alternative.

## Lint + format + test

**Oxlint** does the linting, **Oxfmt** does the formatting, **Vitest** runs the
tests — all bundled in `vite-plus`, with intentionally **no Biome** and no
ESLint/Prettier. Configuration is centralized in the workspace-root
[`vite.config.ts`](vite.config.ts):

- `lint` block — Oxlint with type-aware checking (`typeAware` + `typeCheck` via
  tsgolint, so `vp check` also type-checks). The old ESLint
  `@typescript-eslint/no-unused-vars` rule (allow `_`-prefixed identifiers) is
  ported to the Oxlint `no-unused-vars` rule; `prefer-vite-plus-imports` keeps
  the `vite-plus` / `vite-plus/test` import surface.
- `fmt` block — Oxfmt (`printWidth: 100`, `semi: true`), ignoring `**/dist/**`,
  `**/*.json` (tsconfig comments, Bun-managed manifests), and `**/*.md` — the old
  `.prettierignore` scope.
- Each member's `vite.config.ts` carries its own `pack` (build) and `test`
  config. The `test` block sets `server.deps.inline: ["vite-plus"]` so the
  `vite-plus/test` re-export (which is `export * from "vitest"`) binds to
  `vp test`'s Vitest instance rather than a non-runner entry; the root
  [`bunfig.toml`](bunfig.toml) `linker = "hoisted"` keeps that a single Vitest
  copy under Bun's otherwise-isolated install layout.

CI runs `vp check` plus `vp run -r {build,typecheck,test}` via
[`../.github/workflows/ci.yml`](../.github/workflows/ci.yml) (using
`voidzero-dev/setup-vp`), alongside the Rust crate build/test and shell linting.

### Editor (VS Code)

The `.vscode/` editor configuration is intentionally not vendored.

## Adding a new package

1. `mkdir packages/<name>` and add `package.json` (`@h82/<name>`,
   `private: true`, `"type": "module"`). The `"workspaces": ["*"]` glob picks it
   up automatically. Reference sibling packages with the `workspace:*` protocol.
2. Pin every dependency to an exact, cooldown-valid (≥7 days old) version, and
   add `vite-plus` as `"catalog:"` (the toolchain). Run `vp install` from
   `packages/` to update the single root `bun.lock`.
3. Give the member a `vite.config.ts` with a `pack` block (build config), a
   `test` block (`include` + `server.deps.inline: ["vite-plus"]`), and
   `run.tasks` for `build` / `typecheck` / `test` (each `dependsOn` its workspace
   dependencies' `build`). Copy an existing member's config as the template.
   Lint/format are workspace-wide (root `vite.config.ts`), so no per-member
   lint/format config is needed.
4. Document the package in its own `README.md` and add a row to the members
   table above.
5. Update the root [`AGENTS.md`](../AGENTS.md) `packages/` bullet and the root
   [`README.md`](../README.md) "Repository structure" list in the **same
   commit** (the repo's hard documentation-sync rule).
