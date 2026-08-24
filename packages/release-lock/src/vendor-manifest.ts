import { createHash } from "node:crypto";
import { ResolutionError } from "./github.js";
import type { LockedTool, ToolSpec } from "./types.js";

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

async function fetchText(source: string, url: string): Promise<string> {
  return (await fetchOrThrow(source, url)).text();
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

async function resolveDavMail(name: string, spec: ToolSpec): Promise<LockedTool> {
  const feed = await fetchText(spec.source, spec.source);
  let newestTitle: string | undefined;
  let newestVersion: string | undefined;
  let newestPublishedAt = Number.NEGATIVE_INFINITY;

  for (const match of feed.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)) {
    const item = match[1] ?? "";
    const title = itemField(item, "title");
    const pubDate = itemField(item, "pubDate");
    if (!title || !pubDate) continue;

    const m = /^\/davmail\/([0-9.]+)\/davmail-(?:[0-9.]+(?:-[0-9]+)?)\.zip$/i.exec(title);
    if (!m) continue;

    const version = m[1];
    if (!version) continue;
    const publishedAt = Date.parse(pubDate);
    if (!Number.isFinite(publishedAt)) continue;

    if (publishedAt > newestPublishedAt) {
      newestTitle = title;
      newestVersion = version;
      newestPublishedAt = publishedAt;
    }
  }

  if (!newestTitle || !newestVersion) {
    throw new ResolutionError(spec.source, `${name}: feed contains no matching zip release items`);
  }

  const downloadUrl = `https://downloads.sourceforge.net/project/davmail${newestTitle}`;
  const response = await fetchOrThrow(spec.source, downloadUrl);
  const zipBuffer = Buffer.from(await response.arrayBuffer());
  const sha256 = createHash("sha256").update(zipBuffer).digest("hex");

  return {
    kind: spec.kind,
    source: spec.source,
    version: newestVersion,
    artifacts: {
      "linux-amd64": { url: downloadUrl, sha256 },
      "linux-arm64": { url: downloadUrl, sha256 },
      "darwin-amd64": { url: downloadUrl, sha256 },
      "darwin-arm64": { url: downloadUrl, sha256 },
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
    case "davmail":
      return resolveDavMail(name, spec);
    default:
      throw new ResolutionError(spec.source, `${name}: unknown vendor "${String(spec.vendor)}"`);
  }
}
