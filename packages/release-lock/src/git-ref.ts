import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { ResolutionError } from "./github.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * Git ref resolution — a branch head (or HEAD) resolved to its commit sha,
 * version-only. Replaces the render-time `git ls-remote` calls used by
 * branch-pinned external skills.
 */

export type GitExec = (args: readonly string[]) => Promise<string>;

const execFileAsync = promisify(execFile);

const defaultExec: GitExec = async (args) => {
  const { stdout } = await execFileAsync("git", [...args]);
  return stdout;
};

/** The 40-hex commit sha at the start of `git ls-remote` output. */
export function parseLsRemoteSha(source: string, output: string): string {
  const match = /^[0-9a-f]{40}/.exec(output);
  if (!match) {
    throw new ResolutionError(
      source,
      `could not resolve the ref to a 40-character commit sha: ${JSON.stringify(output)}`,
    );
  }
  return match[0];
}

export async function resolveGitRef(
  name: string,
  spec: ToolSpec,
  exec: GitExec = defaultExec,
): Promise<LockedTool> {
  if (!spec.ref) {
    throw new ResolutionError(spec.source, `${name}: gitRef requires a ref`);
  }
  const args = ["ls-remote", `https://github.com/${spec.source}.git`, spec.ref] as const;
  let output: string;
  try {
    output = await exec(args);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new ResolutionError(spec.source, `${name}: git ls-remote failed: ${detail}`);
  }
  return { kind: spec.kind, source: spec.source, version: parseLsRemoteSha(spec.source, output) };
}
