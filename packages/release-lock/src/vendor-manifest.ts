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

export async function resolveVendorManifest(name: string, spec: ToolSpec): Promise<LockedTool> {
  switch (spec.vendor) {
    case "winbox":
      return resolveWinbox(name, spec);
    case "onePassword":
      return resolveOnePassword(name, spec);
    default:
      throw new ResolutionError(spec.source, `${name}: unknown vendor "${String(spec.vendor)}"`);
  }
}
