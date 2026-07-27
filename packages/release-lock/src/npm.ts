import { ResolutionError } from "./github.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * npm registry resolution — the `latest` dist-tag of a package, version-only.
 *
 * `dist.integrity` (sha512-base64 subresource integrity) is recorded as
 * published for completeness; chezmoi cannot verify it, so the entry stays
 * version-only for consumers, exactly as today's render-time resolution
 * treats it.
 */

interface NpmLatest {
  readonly version: string;
  readonly dist?: { readonly integrity?: string };
}

export async function resolveNpmPackage(name: string, spec: ToolSpec): Promise<LockedTool> {
  const response = await fetch(`https://registry.npmjs.org/${spec.source}/latest`, {
    headers: { accept: "application/json", "user-agent": "h82-release-lock" },
  });
  if (!response.ok) {
    throw new ResolutionError(spec.source, `registry /latest returned HTTP ${response.status}`);
  }
  const body = (await response.json()) as NpmLatest;
  if (typeof body.version !== "string") {
    throw new ResolutionError(spec.source, `${name}: registry response missing version`);
  }
  const integrity = typeof body.dist?.integrity === "string" ? body.dist.integrity : null;
  return { kind: spec.kind, source: spec.source, version: body.version, integrity };
}
