import { authHeaders, ResolutionError } from "./github.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * GitHub tag resolution — the newest tag of a repository, version-only.
 *
 * The tags endpoint lists newest first, one call per repository.
 */

interface GitHubTag {
  readonly name: string;
}

export async function resolveGitHubTag(
  name: string,
  spec: ToolSpec,
  token: string | undefined,
): Promise<LockedTool> {
  const response = await fetch(`https://api.github.com/repos/${spec.source}/tags?per_page=5`, {
    headers: authHeaders(token),
  });
  if (!response.ok) {
    throw new ResolutionError(spec.source, `tags returned HTTP ${response.status}`);
  }
  const tags = (await response.json()) as GitHubTag[];
  if (!Array.isArray(tags)) {
    throw new ResolutionError(spec.source, "tags response is not a list");
  }
  const tag = tags.find((candidate) => typeof candidate.name === "string")?.name;
  if (!tag) {
    throw new ResolutionError(spec.source, `${name} has no tags`);
  }
  return {
    kind: spec.kind,
    source: spec.source,
    version: spec.versionTransform ? spec.versionTransform(tag) : tag,
  };
}
