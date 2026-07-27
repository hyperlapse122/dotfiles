# @h82/release-lock

Resolves external tool releases into the static `.chezmoidata` release lock.

This exists so a chezmoi source-state read performs **no network I/O**. Today
every version, asset URL, and checksum is resolved at render time — partly
through chezmoi's `gitHub*` builtins (HTTP-cached, but only for the 60 seconds
GitHub's `Cache-Control` allows) and partly through `output "curl"` and
`getRedirectedURL`, which are never cached and shell out on every render. Both
fail with no network reachable, so an offline `chezmoi diff` is impossible.

The plan this package implements is
[`docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md`](../../docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md).

## Status

Partial. The `githubRelease` resolver kind is implemented and verified; the
lock file itself and the template migration are not yet landed. Nothing in
`chezmoi apply` consumes this package yet — it currently runs standalone.

| Resolver kind | State |
|---|---|
| `githubRelease` | implemented |
| `githubTag`, `gitlabRelease`, `npm`, `vendorManifest`, `gitRef` | not yet implemented |

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
its source, and an `asset` selector returning the upstream filename for a
platform. Two conventions matter:

- A selector returns `null` for a platform the tool deliberately does not target
  (jq is darwin-only here).
- `unsupportedPlatforms` declares targets upstream genuinely does not build.
  This is declared rather than inferred on purpose: any *other* missing asset is
  a hard error, so a stale asset pattern cannot hide behind a silent skip. That
  strictness is what surfaced `buf` naming its linux arm64 build `aarch64` while
  darwin and windows use `arm64`.

## Verification

```sh
vp test            # unit tests, network stubbed
vp run typecheck   # tsc --noEmit
```
