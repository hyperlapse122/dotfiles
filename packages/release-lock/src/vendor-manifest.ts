import { ResolutionError } from "./github.js";
import { ALL_PLATFORMS, platformKey, type PlatformKey } from "./platforms.js";
import type { LockedArtifact, LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * Vendor manifest resolution — the three non-registry sources resolved at
 * render time today:
 *
 * - claude: downloads.claude.ai `latest` release id + per-id `manifest.json`
 *   carrying per-platform binary name, sha256 checksum, and size. The
 *   manifest's platform ids map onto lock keys, with the musl builds landing
 *   in the `-musl` keys (KTD11).
 * - antigravity (agy): one GCS manifest per platform carrying `url` and a
 *   `sha512` digest. chezmoi externals verify sha256 only, so the sha512 is
 *   recorded as published and `sha256` stays null — exactly the behaviour of
 *   today's template, which records it without enforcing.
 * - winbox: MikroTik's LATEST.4 endpoint, a bare version string. Upstream
 *   publishes no digest anywhere, so the entry is version-only.
 */

const HEADERS = { "user-agent": "h82-release-lock" } as const;

async function fetchOrThrow(source: string, url: string): Promise<Response> {
  const response = await fetch(url, { headers: HEADERS });
  if (!response.ok) {
    throw new ResolutionError(source, `${url} returned HTTP ${response.status}`);
  }
  return response;
}

async function fetchJson(source: string, url: string): Promise<unknown> {
  return (await fetchOrThrow(source, url)).json();
}

async function fetchText(source: string, url: string): Promise<string> {
  return (await fetchOrThrow(source, url)).text();
}

const HEX: Readonly<Record<64 | 128, RegExp>> = { 64: /^[0-9a-f]{64}$/, 128: /^[0-9a-f]{128}$/ };

/** Lowercase hex of the requested length, or null rather than a bad digest. */
function normalizeHex(digest: unknown, length: 64 | 128): string | null {
  if (typeof digest !== "string") return null;
  const hex = digest.toLowerCase();
  return HEX[length].test(hex) ? hex : null;
}

/** Manifest platform id -> lock key, in deterministic iteration order. */
const CLAUDE_PLATFORMS: Readonly<Record<string, PlatformKey>> = {
  "linux-x64": "linux-amd64",
  "linux-arm64": "linux-arm64",
  "linux-x64-musl": "linux-amd64-musl",
  "linux-arm64-musl": "linux-arm64-musl",
  "darwin-x64": "darwin-amd64",
  "darwin-arm64": "darwin-arm64",
  "win32-x64": "windows-amd64",
  "win32-arm64": "windows-arm64",
};

interface ClaudeManifest {
  readonly version: string;
  readonly platforms: Readonly<
    Record<string, { readonly binary: string; readonly checksum: string; readonly size: number }>
  >;
}

async function resolveClaude(name: string, spec: ToolSpec): Promise<LockedTool> {
  const id = (await fetchText(spec.source, `${spec.source}/latest`)).trim();
  const manifest = (await fetchJson(
    spec.source,
    `${spec.source}/${id}/manifest.json`,
  )) as ClaudeManifest;
  if (typeof manifest.version !== "string" || typeof manifest.platforms !== "object") {
    throw new ResolutionError(spec.source, `${name}: manifest missing version or platforms`);
  }

  const artifacts: Partial<Record<PlatformKey, LockedArtifact>> = {};
  for (const platformId of Object.keys(manifest.platforms)) {
    if (!CLAUDE_PLATFORMS[platformId]) {
      throw new ResolutionError(
        spec.source,
        `${name}: manifest publishes unknown platform id "${platformId}"`,
      );
    }
  }
  // Iterate the fixed mapping, not the manifest, so an upstream key reorder
  // never churns the lock. A known platform the manifest drops is a hard
  // error, never a silent skip: a partial artifacts block would blank that
  // platform's entry in the merged lock and break every render on it.
  for (const [platformId, key] of Object.entries(CLAUDE_PLATFORMS)) {
    const entry = manifest.platforms[platformId];
    if (!entry) {
      throw new ResolutionError(
        spec.source,
        `${name}: manifest missing known platform id "${platformId}"`,
      );
    }
    artifacts[key] = {
      url: `${spec.source}/${id}/${platformId}/${entry.binary}`,
      sha256: normalizeHex(entry.checksum, 64),
      ...(typeof entry.size === "number" ? { size: entry.size } : {}),
    };
  }

  return { kind: spec.kind, source: spec.source, version: manifest.version, artifacts };
}

interface AntigravityManifest {
  readonly version: string;
  readonly url: string;
  readonly sha512: string;
}

async function resolveAntigravity(name: string, spec: ToolSpec): Promise<LockedTool> {
  const artifacts: Partial<Record<PlatformKey, LockedArtifact>> = {};
  let version: string | undefined;

  // Fetch all platforms concurrently, then validate in ALL_PLATFORMS order so
  // the error that surfaces is identical to sequential resolution.
  const settled = await Promise.allSettled(
    ALL_PLATFORMS.map((platform) =>
      fetchJson(spec.source, `${spec.source}/${platform.os}_${platform.arch}.json`),
    ),
  );

  for (const [index, platform] of ALL_PLATFORMS.entries()) {
    const result = settled[index]!;
    if (result.status === "rejected") throw result.reason;
    const platformId = `${platform.os}_${platform.arch}`;
    const manifest = result.value as AntigravityManifest;
    if (typeof manifest.version !== "string" || typeof manifest.url !== "string") {
      throw new ResolutionError(spec.source, `${name}: ${platformId} manifest missing fields`);
    }
    if (version === undefined) version = manifest.version;
    if (manifest.version !== version) {
      throw new ResolutionError(
        spec.source,
        `${name}: platform manifests disagree on version (${version} vs ${manifest.version})`,
      );
    }
    artifacts[platformKey(platform)] = {
      url: manifest.url,
      sha256: null,
      sha512: normalizeHex(manifest.sha512, 128),
    };
  }

  return { kind: spec.kind, source: spec.source, version: version as string, artifacts };
}

async function resolveWinbox(name: string, spec: ToolSpec): Promise<LockedTool> {
  const version = (await fetchText(spec.source, spec.source)).trim();
  if (!/^[0-9]+\.[0-9]+/.test(version)) {
    throw new ResolutionError(spec.source, `${name}: unexpected version "${version}"`);
  }
  return { kind: spec.kind, source: spec.source, version };
}

export async function resolveVendorManifest(name: string, spec: ToolSpec): Promise<LockedTool> {
  switch (spec.vendor) {
    case "claude":
      return resolveClaude(name, spec);
    case "antigravity":
      return resolveAntigravity(name, spec);
    case "winbox":
      return resolveWinbox(name, spec);
    default:
      throw new ResolutionError(spec.source, `${name}: unknown vendor "${String(spec.vendor)}"`);
  }
}
