import { ResolutionError } from "./github.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * Vendor manifest resolution — the non-registry sources resolved at render
 * time today:
 *
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

export async function resolveVendorManifest(name: string, spec: ToolSpec): Promise<LockedTool> {
  switch (spec.vendor) {
    case "winbox":
      return resolveWinbox(name, spec);
    default:
      throw new ResolutionError(spec.source, `${name}: unknown vendor "${String(spec.vendor)}"`);
  }
}
