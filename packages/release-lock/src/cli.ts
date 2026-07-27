import { REGISTRY } from "./registry.js";
import { resolveGitHubRelease } from "./github.js";
import { resolveGitHubTag } from "./github-tag.js";
import { resolveGitLabRelease } from "./gitlab.js";
import { resolveGitRef } from "./git-ref.js";
import { resolveNpmPackage } from "./npm.js";
import { resolveVendorManifest } from "./vendor-manifest.js";
import { mergeLocks, readLock, serializeLock, sortTools, writeLock } from "./lock.js";
import type { LockedTool, ReleaseLock, ToolSpec } from "./types.js";

/**
 * Resolve every registered tool into the release lock.
 *
 * With `--out <path>` the resolution is overlaid onto the file already there and
 * written back; without it the lock goes to stdout. Either way a source that
 * fails to resolve is reported on stderr and omitted, so overlaying keeps its
 * last good entry rather than blanking it. Exit code 1 signals that at least one
 * source failed, whether or not anything was written.
 */

function githubToken(): string | undefined {
  const env = process.env;
  return env["CHEZMOI_GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_TOKEN"];
}

export function outPath(argv: readonly string[]): string | undefined {
  const flag = argv.indexOf("--out");
  if (flag === -1) return undefined;
  const value = argv[flag + 1];
  if (value === undefined || value.startsWith("--")) throw new Error("--out requires a path");
  return value;
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
  const failures: string[] = [];
  const tools: Record<string, LockedTool> = {};

  const settled = await Promise.all(
    Object.entries(REGISTRY).map(async ([name, spec]) => {
      try {
        return { name, tool: await resolve(name, spec, token) };
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

const destination = outPath(process.argv.slice(2));
const { lock, failures } = await resolveAll(githubToken());

for (const failure of failures) process.stderr.write(`release-lock: ${failure}\n`);

if (destination === undefined) process.stdout.write(serializeLock(lock));
else await writeLock(destination, mergeLocks(await readLock(destination), lock));

if (failures.length > 0) process.exitCode = 1;
