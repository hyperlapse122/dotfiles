import { createHash } from "node:crypto";
import { ResolutionError } from "./github.js";
import { ALL_PLATFORMS, platformKey, type PlatformKey } from "./platforms.js";
import type { LockedArtifact, LockedTool, ToolSpec } from "./types.js";
export { ResolutionError };

/**
 * Vendor manifest resolution — the non-registry sources resolved at render
 * time today:
 *
 * - winbox: MikroTik's LATEST.4 endpoint, a bare version string. Upstream
 *   publishes no digest anywhere, so the entry is version-only.
 * - onePassword: an RSS feed whose latest dated item names the Linux version.
 *   Its arm64 tarball has no published checksum, so it is never downloaded here.
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

function normalizeHex(digest: unknown, length: 64 | 128): string | null {
  if (typeof digest !== "string") return null;
  const hex = digest.toLowerCase();
  return HEX[length].test(hex) ? hex : null;
}

const CLAUDE_PLATFORMS: Readonly<Record<string, PlatformKey>> = {
  "linux-x64": "linux-amd64",
  "linux-arm64": "linux-arm64",
  "linux-x64-musl": "linux-amd64-musl",
  "linux-arm64-musl": "linux-arm64-musl",
  "darwin-x64": "darwin-amd64",
  "darwin-arm64": "darwin-arm64",
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

function itemField(item: string, field: "title" | "pubDate"): string | undefined {
  const match = new RegExp(`<${field}\\b[^>]*>([\\s\\S]*?)<\\/${field}>`, "i").exec(item);
  const value = match?.[1];
  if (value === undefined) return undefined;
  return value
    .trim()
    .replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, "$1")
    .trim();
}

function newestOnePasswordTitle(name: string, source: string, feed: string): string {
  let newestTitle: string | undefined;
  let newestPublishedAt = Number.NEGATIVE_INFINITY;

  for (const match of feed.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)) {
    const item = match[1] ?? "";
    const title = itemField(item, "title");
    const pubDate = itemField(item, "pubDate");
    if (!title || !pubDate) {
      throw new ResolutionError(source, `${name}: feed item is missing title or pubDate`);
    }
    const publishedAt = Date.parse(pubDate);
    if (!Number.isFinite(publishedAt)) {
      throw new ResolutionError(source, `${name}: invalid pubDate "${pubDate}"`);
    }
    if (publishedAt > newestPublishedAt) {
      newestTitle = title;
      newestPublishedAt = publishedAt;
    }
  }

  if (newestTitle === undefined) {
    throw new ResolutionError(source, `${name}: feed contains no release items`);
  }
  return newestTitle;
}

async function resolveOnePassword(name: string, spec: ToolSpec): Promise<LockedTool> {
  const title = newestOnePasswordTitle(
    name,
    spec.source,
    await fetchText(spec.source, spec.source),
  );
  const titleMatch = /^1Password for Linux (.+)$/.exec(title);
  if (!titleMatch) {
    throw new ResolutionError(spec.source, `${name}: unexpected release title "${title}"`);
  }
  const version = titleMatch[1];
  if (version === undefined || !/^[0-9]+(?:\.[0-9]+)+$/.test(version)) {
    throw new ResolutionError(spec.source, `${name}: unexpected version "${version ?? ""}"`);
  }

  return {
    kind: spec.kind,
    source: spec.source,
    version,
    artifacts: {
      "linux-arm64": {
        url: `https://downloads.1password.com/linux/tar/stable/aarch64/1password-${version}.arm64.tar.gz`,
        sha256: null,
      },
    },
  };
}

interface FlutterRelease {
  hash: string;
  channel: string;
  version: string;
  dart_sdk_arch?: string;
  archive: string;
  sha256: string;
}

interface FlutterManifest {
  base_url: string;
  current_release: {
    stable: string;
  };
  releases: FlutterRelease[];
}

async function resolveFlutter(name: string, spec: ToolSpec): Promise<LockedTool> {
  const linuxUrl = `${spec.source.replace(/\/+$/, "")}/releases_linux.json`;
  const macosUrl = `${spec.source.replace(/\/+$/, "")}/releases_macos.json`;

  const [linuxText, macosText] = await Promise.all([
    fetchText(spec.source, linuxUrl),
    fetchText(spec.source, macosUrl),
  ]);

  let linuxManifest: FlutterManifest;
  let macosManifest: FlutterManifest;
  try {
    linuxManifest = JSON.parse(linuxText) as FlutterManifest;
    macosManifest = JSON.parse(macosText) as FlutterManifest;
  } catch (err) {
    throw new ResolutionError(
      spec.source,
      `${name}: invalid JSON manifest: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  const linuxStableHash = linuxManifest.current_release?.stable;
  if (!linuxStableHash) {
    throw new ResolutionError(spec.source, `${name}: missing linux stable release hash`);
  }
  const linuxRelease = linuxManifest.releases?.find((r) => r.hash === linuxStableHash);
  if (!linuxRelease) {
    throw new ResolutionError(
      spec.source,
      `${name}: linux stable release ${linuxStableHash} not found in releases`,
    );
  }

  const macosStableHash = macosManifest.current_release?.stable;
  if (!macosStableHash) {
    throw new ResolutionError(spec.source, `${name}: missing macos stable release hash`);
  }
  const macosArm64 = macosManifest.releases?.find(
    (r) => r.hash === macosStableHash && r.dart_sdk_arch === "arm64",
  );
  const macosX64 = macosManifest.releases?.find(
    (r) => r.hash === macosStableHash && (r.dart_sdk_arch === "x64" || !r.dart_sdk_arch),
  );

  if (!macosArm64 || !macosX64) {
    throw new ResolutionError(
      spec.source,
      `${name}: macos arm64 or x64 stable release not found in releases`,
    );
  }

  const linuxBase = linuxManifest.base_url.replace(/\/+$/, "");
  const macosBase = macosManifest.base_url.replace(/\/+$/, "");

  return {
    kind: spec.kind,
    source: spec.source,
    version: linuxRelease.version,
    artifacts: {
      "linux-amd64": {
        url: `${linuxBase}/${linuxRelease.archive}`,
        sha256: linuxRelease.sha256,
      },
      "linux-arm64": {
        url: `${linuxBase}/${linuxRelease.archive}`,
        sha256: linuxRelease.sha256,
        emulated: true,
      },
      "darwin-amd64": {
        url: `${macosBase}/${macosX64.archive}`,
        sha256: macosX64.sha256,
      },
      "darwin-arm64": {
        url: `${macosBase}/${macosArm64.archive}`,
        sha256: macosArm64.sha256,
      },
    },
  };
}

async function fetchBinary(
  source: string,
  url: string,
): Promise<{ buffer: Buffer; sha256: string; size: number }> {
  const response = await fetchOrThrow(source, url);
  const arrayBuffer = await response.arrayBuffer();
  const buffer = Buffer.from(arrayBuffer);
  const sha256 = createHash("sha256").update(buffer).digest("hex");
  return { buffer, sha256, size: buffer.length };
}

async function resolveAndroidCli(name: string, spec: ToolSpec): Promise<LockedTool> {
  const base = spec.source.replace(/\/+$/, "");
  const linuxUrl = `${base}/linux_x86_64/android`;
  const darwinArm64Url = `${base}/darwin_arm64/android`;
  const darwinX64Url = `${base}/darwin_x86_64/android`;

  const [linuxBinary, darwinArm64Binary, darwinX64Binary] = await Promise.all([
    fetchBinary(spec.source, linuxUrl),
    fetchBinary(spec.source, darwinArm64Url),
    fetchBinary(spec.source, darwinX64Url),
  ]);

  const match = linuxBinary.buffer.toString("latin1").match(/version=([0-9.]+)/);
  if (!match || !match[1]) {
    throw new ResolutionError(spec.source, `${name}: could not extract version from binary`);
  }
  const version = match[1];

  return {
    kind: spec.kind,
    source: spec.source,
    version,
    artifacts: {
      "linux-amd64": {
        url: linuxUrl,
        sha256: linuxBinary.sha256,
        size: linuxBinary.size,
      },
      "linux-arm64": {
        url: linuxUrl,
        sha256: linuxBinary.sha256,
        size: linuxBinary.size,
        emulated: true,
      },
      "darwin-amd64": {
        url: darwinX64Url,
        sha256: darwinX64Binary.sha256,
        size: darwinX64Binary.size,
      },
      "darwin-arm64": {
        url: darwinArm64Url,
        sha256: darwinArm64Binary.sha256,
        size: darwinArm64Binary.size,
      },
    },
  };
}

export async function resolveVendorManifest(name: string, spec: ToolSpec): Promise<LockedTool> {
  switch (spec.vendor) {
    case "winbox":
      return resolveWinbox(name, spec);
    case "onePassword":
      return resolveOnePassword(name, spec);
    case "flutter":
      return resolveFlutter(name, spec);
    case "android":
      return resolveAndroidCli(name, spec);
    case "claude":
      return resolveClaude(name, spec);
    case "antigravity":
      return resolveAntigravity(name, spec);
    default:
      throw new ResolutionError(spec.source, `${name}: unknown vendor "${String(spec.vendor)}"`);
  }
}
