import {
  ALL_PLATFORMS,
  ALL_PLATFORMS_WITH_MUSL,
  platformKey,
  type PlatformKey,
} from "./platforms.js";
import { ResolutionError } from "./types.js";
import type { LockedArtifact, LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * GitHub release resolution.
 *
 * One `releases/latest` call yields the tag and, for every asset, its name,
 * download URL, and sha256 digest. That digest is why the refresh never has to
 * download an artifact to checksum it — a linux runner can lock darwin entries
 * from the same response.
 */

interface GitHubAsset {
  readonly name: string;
  readonly browser_download_url: string;
  /** `sha256:<hex>`, or absent on releases predating the field. */
  readonly digest?: string | null;
}

interface GitHubRelease {
  readonly tag_name: string;
  readonly assets: readonly GitHubAsset[];
}

export function authHeaders(token: string | undefined): Record<string, string> {
  const headers: Record<string, string> = {
    accept: "application/vnd.github+json",
    "user-agent": "h82-release-lock",
  };
  if (token) headers["authorization"] = `Bearer ${token}`;
  return headers;
}

/** `sha256:abc…` -> `abc…`. Anything else yields null rather than a bad digest. */
export function normalizeDigest(digest: string | null | undefined): string | null {
  if (!digest) return null;
  const prefix = "sha256:";
  if (!digest.startsWith(prefix)) return null;
  const hex = digest.slice(prefix.length).toLowerCase();
  return /^[0-9a-f]{64}$/.test(hex) ? hex : null;
}

async function fetchReleaseJson(
  source: string,
  path: string,
  label: string,
  token: string | undefined,
): Promise<unknown> {
  const response = await fetch(`https://api.github.com/repos/${source}/${path}`, {
    headers: authHeaders(token),
  });
  if (!response.ok) {
    throw new ResolutionError(source, `${label} returned HTTP ${response.status}`);
  }
  return response.json();
}

export async function fetchLatestRelease(
  source: string,
  token: string | undefined,
): Promise<GitHubRelease> {
  const release = (await fetchReleaseJson(
    source,
    "releases/latest",
    "releases/latest",
    token,
  )) as GitHubRelease;
  if (typeof release.tag_name !== "string" || !Array.isArray(release.assets)) {
    throw new ResolutionError(source, "releases/latest response missing tag_name or assets");
  }
  return release;
}

/**
 * The newest release whose tag carries `tagPrefix`, from one release-list
 * call. KTD10: a repo that interleaves several tag trains
 * (compound-engineering-* next to marketplace-*, cli-*) must filter, because
 * `releases/latest` would eventually land on the wrong train.
 */
export async function fetchLatestReleaseByPrefix(
  source: string,
  tagPrefix: string,
  token: string | undefined,
): Promise<GitHubRelease> {
  const releases = (await fetchReleaseJson(
    source,
    "releases?per_page=100",
    "releases",
    token,
  )) as GitHubRelease[];
  if (!Array.isArray(releases)) {
    throw new ResolutionError(source, "releases response is not a list");
  }
  const release = releases.find(
    (candidate) =>
      typeof candidate.tag_name === "string" &&
      candidate.tag_name.startsWith(tagPrefix) &&
      Array.isArray(candidate.assets),
  );
  if (!release) {
    throw new ResolutionError(source, `no release tag carries the prefix "${tagPrefix}"`);
  }
  return release;
}

/**
 * Resolve one tool to its locked entry.
 *
 * A selector returning null means the tool publishes nothing for that platform,
 * which is expected. A selector naming an asset the release does not contain is
 * an error — that is a stale pattern, not an absent build.
 */
export async function resolveGitHubRelease(
  name: string,
  spec: ToolSpec,
  token: string | undefined,
): Promise<LockedTool> {
  const release = spec.tagPrefix
    ? await fetchLatestReleaseByPrefix(spec.source, spec.tagPrefix, token)
    : await fetchLatestRelease(spec.source, token);
  const tag = release.tag_name;

  if (!spec.asset) {
    return { kind: spec.kind, source: spec.source, version: tag };
  }

  const byName = new Map(release.assets.map((asset) => [asset.name, asset]));
  const artifacts: Partial<Record<PlatformKey, LockedArtifact>> = {};
  const emulated = new Set(spec.emulatedPlatforms ?? []);
  const platforms = spec.linuxMusl ? ALL_PLATFORMS_WITH_MUSL : ALL_PLATFORMS;

  for (const platform of platforms) {
    const key = platformKey(platform);
    const viaEmulation = emulated.has(key);
    const target = viaEmulation ? { os: platform.os, arch: "amd64" as const } : platform;

    const assetName = spec.asset(target, tag);
    if (assetName === null) continue;

    const asset = byName.get(assetName);
    if (!asset) {
      throw new ResolutionError(
        spec.source,
        `${name} expected asset "${assetName}" for ${key}, ` +
          `but release ${tag} does not publish it`,
      );
    }

    const resolved = {
      url: asset.browser_download_url,
      sha256: normalizeDigest(asset.digest),
    };
    artifacts[key] = viaEmulation ? { ...resolved, emulated: true } : resolved;
  }

  return { kind: spec.kind, source: spec.source, version: tag, artifacts };
}
