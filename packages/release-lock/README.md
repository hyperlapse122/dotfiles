# @h82/release-lock

Resolves external tool releases into the static `.chezmoidata` release lock.

This exists so a chezmoi source-state read performs **no network I/O**.
Versions, asset URLs, and checksums used to be resolved at render time —
partly through chezmoi's `gitHub*` builtins (HTTP-cached, but only for the 60
seconds GitHub's `Cache-Control` allows) and partly through `output "curl"`
and `getRedirectedURL`, which were never cached and shelled out on every
render. Both failed with no network reachable, so an offline `chezmoi diff`
was impossible.

The plan this package implements is
[`docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md`](../../docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md).

## Status

All six resolver kinds are implemented, the committed
`.chezmoidata/releases.json` covers every render-time resolution source in the
repo, and the lock is now the sole version/URL/checksum source: every
`.chezmoiexternals` file and every version-consuming script template reads it
through `.chezmoitemplates/release-lock-ref.tmpl`. A source-state read performs
no network I/O; re-run this package to refresh the lock.

| Resolver kind | State |
|---|---|
| `githubRelease` | implemented |
| `githubTag` | implemented |
| `gitlabRelease` | implemented |
| `npm` | implemented |
| `vendorManifest` | implemented |
| `gitRef` | implemented |

## Why digests are free

GitHub's `releases/latest` response carries a `digest` field on every asset, so
one call per repository yields the tag, each platform's asset URL, **and** its
sha256. A Linux runner can therefore lock darwin and windows artifacts without
downloading them — verified by hashing a real `darwin-arm64` artifact and
comparing it to the recorded digest.

## Usage

```sh
cd packages/release-lock
bun run src/cli.ts            # prints the resolved lock as JSON on stdout
```

A source that fails to resolve is reported on stderr and omitted from the
emitted lock, and the process exits non-zero. Callers merge the emission over
the committed lock so a failed entry keeps its previous value rather than being
blanked.

## Adding a tool

Add an entry to [`src/registry.ts`](src/registry.ts) naming its resolver kind,
its source, and — for tools with downloadable artifacts — an `asset` selector
returning the upstream filename for a platform. Conventions that matter:

- A selector returns `null` for a platform the tool deliberately does not
  target (jq is darwin-only here; pi and aoe skip windows).
- `emulatedPlatforms` declares targets upstream genuinely does not build,
  served by the amd64 artifact under emulation. This is declared rather than
  inferred on purpose: any *other* missing asset is a hard error, so a stale
  asset pattern cannot hide behind a silent skip. That strictness is what
  surfaced `buf` naming its linux arm64 build `aarch64` while darwin and
  windows use `arm64`.
- `tagPrefix` (githubRelease) resolves the newest release whose tag carries
  the prefix instead of `releases/latest`, for repos that interleave several
  tag trains (compound-engineering next to marketplace-*/cli-*).
- `linuxMusl` (githubRelease) locks the distinct static-musl linux builds
  under `-musl` platform keys next to the glibc ones (agent-browser; claude's
  vendor manifest maps its musl platform ids onto the same keys).
- `versionTransform` (githubTag) applies the tag-shape transform in the
  registry so consumers read the locked version verbatim — e.g. stripping the
  leading `v` for the npm-pinned OpenCode plugins.
- npm entries record `dist.integrity` and the antigravity manifest its
  `sha512` as published; both are informational only — chezmoi externals
  verify sha256, so those entries stay version-only/sha256-null for
  consumers.

## Verification

```sh
vp test            # unit tests, network stubbed
vp run typecheck   # tsc --noEmit
```
