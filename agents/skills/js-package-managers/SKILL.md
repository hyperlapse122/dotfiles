---
name: js-package-managers
description: >
  Playbook for the hardened npm / pnpm / Yarn Berry / Bun policy. Load this
  BEFORE editing a `package.json` dependency, unblocking a package's
  install-time lifecycle script, correcting a version range to an exact pin,
  or handling a "version too fresh" cooldown failure. It covers the
  per-manager lifecycle-script override mechanics (the narrowest-scope opt-in
  for each manager), the exact-version-pinning correction rule, and the
  1-week cooldown gate handling. Do NOT load it for ordinary `import`/usage of
  an already-installed package, for non-JS dependency systems, or for running
  scripts that don't touch dependency resolution. The binding one-liners
  (preserve the three switches; pin exact; never lower the cooldown) are in
  core AGENTS.md and apply regardless.
---

# JavaScript package managers

User-global config hardens **npm, pnpm, Yarn, and Bun** against supply-chain attacks via
three switches. **MUST** preserve all three:

| Switch | npm | pnpm | Yarn Berry | Bun |
|---|---|---|---|---|
| Lifecycle scripts disabled | `ignore-scripts` | `ignore-scripts` | `enableScripts: false` | `ignoreScripts` |
| Exact version pinning | `save-exact` | `save-exact` | `defaultSemverRangePrefix: ""` | `[install] exact` |
| 1-week cooldown | `min-release-age=7` (days) | `minimumReleaseAge: 10080` (min) | `npmMinimalAgeGate: 10080` (min) | `minimumReleaseAge = 604800` (sec) |

**MUST NOT** edit user-global configs (`~/.npmrc`, `~/.yarnrc.yml`, `~/.bunfig.toml`,
`~/.config/pnpm/config.yaml`, or per-OS equivalents) to relax any switch. The per-project
escape hatches are the supported override.

## Overriding the lifecycle-script block

Opt in at the **narrowest possible scope**. Per-manager mechanics + the
"name-the-behaviour" requirement → [`references/override-mechanics.md`](references/override-mechanics.md).

## Exact version pinning

- Every dependency in every `package.json` **MUST** be pinned to an exact version — no `^`,
  `~`, `>=`, `latest`, `*`, `x`.
- The user-global config produces exact specs automatically via `yarn add` / `npm install`
  / `pnpm add` / `bun add` — agents **SHOULD NOT** pass any range flag.
- **MUST** correct any existing range specifier to an exact version when modifying a
  `package.json` for any reason.
- **MUST NOT** introduce a new range specifier.
- **MUST NOT** edit a lockfile by hand to dodge the rule.
- **Exception**: a project-level `AGENTS.md` may permit ranges where genuinely required
  (peer-dep flexibility, library `package.json` authored for downstream consumers) — state
  the exception explicitly when applying it.

## Cooldown gate (1 week)

A version must be **at least one week old** before any manager resolves it. "Does not meet
the minimumReleaseAge constraint" (or equivalent) means the version is too fresh and
**MUST NOT** be installed.

- **MUST** pin to the most recent version that already satisfies the gate.
- **MUST NOT** add the package to a preapproved/exclude list (`npmPreapprovedPackages` in
  Yarn, `minimumReleaseAgeExclude` in pnpm, `minimumReleaseAgeExcludes` in Bun) without
  explicit per-package user approval.
- **MUST NOT** lower the cooldown value in any user-global or project-level config to work
  around a fresh-version failure.
