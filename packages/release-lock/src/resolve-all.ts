import { REGISTRY } from "./registry.js";
import { resolveGitHubRelease } from "./github.js";
import { resolveGitHubTag } from "./github-tag.js";
import { resolveGitLabRelease } from "./gitlab.js";
import { resolveGitRef } from "./git-ref.js";
import { resolveNpmPackage } from "./npm.js";
import { resolveVendorManifest } from "./vendor-manifest.js";
import { sortTools } from "./lock.js";
import type { LockedTool, Registry, ReleaseLock, ResolverKind, ToolSpec } from "./types.js";

/**
 * Whole-registry resolution, importable without side effects.
 *
 * Kept separate from `cli.ts` — which executes the run at module top level —
 * so tests can drive resolution directly. A source that fails to resolve is
 * omitted from the returned lock and reported in `failures`, so overlaying the
 * result keeps its last good entry rather than blanking it.
 */

export type ResolverFn = (
  name: string,
  spec: ToolSpec,
  token: string | undefined,
) => Promise<LockedTool>;

/**
 * The kind -> resolver dispatch, as a table so its wiring is directly
 * assertable. `gitRef` takes a wrapper because `resolveGitRef`'s third
 * parameter is the `GitExec`, not the token.
 */
export const RESOLVERS: Record<ResolverKind, ResolverFn> = {
  githubRelease: resolveGitHubRelease,
  githubTag: resolveGitHubTag,
  gitlabRelease: resolveGitLabRelease,
  npm: resolveNpmPackage,
  vendorManifest: resolveVendorManifest,
  gitRef: (name, spec) => resolveGitRef(name, spec),
};

export async function resolveAll(
  token: string | undefined,
  registry: Registry = REGISTRY,
): Promise<{
  lock: ReleaseLock;
  failures: string[];
}> {
  const failures: string[] = [];
  const tools: Record<string, LockedTool> = {};

  const settled = await Promise.all(
    Object.entries(registry).map(async ([name, spec]) => {
      try {
        return { name, tool: await RESOLVERS[spec.kind](name, spec, token) };
      } catch (error) {
        return { name, failure: error instanceof Error ? error.message : String(error) };
      }
    }),
  );

  for (const result of settled) {
    if ("tool" in result) tools[result.name] = result.tool;
    else failures.push(result.failure);
  }

  return { lock: { releases: { tools: sortTools(tools) } }, failures };
}
