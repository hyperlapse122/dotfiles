import { ResolutionError } from "./github.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * GitLab release resolution — the tag behind `releases/permalink/latest`,
 * version-only. Replaces the render-time `getRedirectedURL` + `curl` pair in
 * `.chezmoitemplates/glab-release-ref.tmpl` (fetch follows the redirect the
 * same way). One `glab` lock key serves the binary and both bundled skills
 * (AE5), so they can never drift apart by configuration.
 */

interface GitLabRelease {
  readonly tag_name: string;
}

export async function resolveGitLabRelease(name: string, spec: ToolSpec): Promise<LockedTool> {
  const response = await fetch(`${spec.source}/releases/permalink/latest`, {
    headers: { "user-agent": "h82-release-lock" },
  });
  if (!response.ok) {
    throw new ResolutionError(
      spec.source,
      `releases/permalink/latest returned HTTP ${response.status}`,
    );
  }
  const release = (await response.json()) as GitLabRelease;
  if (typeof release.tag_name !== "string") {
    throw new ResolutionError(spec.source, `${name}: response missing tag_name`);
  }
  return { kind: spec.kind, source: spec.source, version: release.tag_name };
}
