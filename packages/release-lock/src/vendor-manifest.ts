import { ResolutionError } from "./github.js";
import type { PlatformKey } from "./platforms.js";
import type { LockedArtifact, LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * Vendor manifest resolution — the two non-registry sources resolved at
 * render time today:
 *
 * - claude: downloads.claude.ai `latest` release id + per-id `manifest.json`
 *   carrying per-platform binary name, sha256 checksum, and size. The
 *   manifest's platform ids map onto lock keys, with the musl builds landing
 *   in the `-musl` keys (KTD11).
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

const SHA256 = /^[0-9a-f]{64}$/;

/** Lowercase hex sha256, or null rather than a bad digest. */
function normalizeSha256(digest: unknown): string | null {
  if (typeof digest !== "string") return null;
  const hex = digest.toLowerCase();
  return SHA256.test(hex) ? hex : null;
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
      sha256: normalizeSha256(entry.checksum),
      ...(typeof entry.size === "number" ? { size: entry.size } : {}),
    };
  }

  return { kind: spec.kind, source: spec.source, version: manifest.version, artifacts };
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
    case "winbox":
      return resolveWinbox(name, spec);
    default:
      throw new ResolutionError(spec.source, `${name}: unknown vendor "${String(spec.vendor)}"`);
  }
}
