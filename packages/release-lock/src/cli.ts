import { REGISTRY } from "./registry.js";
import { resolveGitHubRelease } from "./github.js";
import { resolveGitHubTag } from "./github-tag.js";
import { resolveGitLabRelease } from "./gitlab.js";
import { resolveGitRef } from "./git-ref.js";
import { resolveNpmPackage } from "./npm.js";
import { resolveVendorManifest } from "./vendor-manifest.js";
import type { LockedTool, ReleaseLock, ToolSpec } from "./types.js";

/**
 * Resolve every registered tool and print the lock as JSON on stdout.
 *
 * A source that fails to resolve is reported on stderr and omitted from the
 * emitted lock; the caller merges the emission over the committed lock so a
 * failed entry keeps its previous value rather than being blanked.
 * Exit code 1 signals that at least one source failed.
 */

function githubToken(): string | undefined {
  const env = process.env;
  return env["CHEZMOI_GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_TOKEN"];
}

/** Object keys in sorted order so an unchanged upstream yields an identical file. */
function sortedTools(tools: Record<string, LockedTool>): Record<string, LockedTool> {
  return Object.fromEntries(Object.entries(tools).sort(([a], [b]) => a.localeCompare(b)));
}

function resolve(name: string, spec: ToolSpec, token: string | undefined): Promise<LockedTool> {
  switch (spec.kind) {
    case "githubRelease":
      return resolveGitHubRelease(name, spec, token);
    case "githubTag":
      return resolveGitHubTag(name, spec, token);
    case "gitlabRelease":
      return resolveGitLabRelease(name, spec);
    case "npm":
      return resolveNpmPackage(name, spec);
    case "vendorManifest":
      return resolveVendorManifest(name, spec);
    case "gitRef":
      return resolveGitRef(name, spec);
  }
}

export async function resolveAll(token: string | undefined): Promise<{
  lock: ReleaseLock;
  failures: string[];
}> {
  const entries = Object.entries(REGISTRY);
  const failures: string[] = [];
  const tools: Record<string, LockedTool> = {};

  const settled = await Promise.all(
    entries.map(async ([name, spec]) => {
      try {
        return { name, tool: await resolve(name, spec, token) };
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        return { name, failure: detail };
      }
    }),
  );

  for (const result of settled) {
    if ("tool" in result) tools[result.name] = result.tool;
    else failures.push(result.failure);
  }

  return { lock: { releases: { tools: sortedTools(tools) } }, failures };
}

const { lock, failures } = await resolveAll(githubToken());

for (const failure of failures) process.stderr.write(`release-lock: ${failure}\n`);
process.stdout.write(`${JSON.stringify(lock, null, 2)}\n`);
if (failures.length > 0) process.exitCode = 1;
