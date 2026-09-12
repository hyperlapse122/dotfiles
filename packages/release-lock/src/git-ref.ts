import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { authHeaders, ResolutionError } from "./github.js";
import { fetchWithRetry } from "./http.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { defaultExec, ResolutionError };

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
  token?: string,
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
  const sha = parseLsRemoteSha(spec.source, output);

  const skillPath = spec.skillPath ?? `skills/${name}`;
  const url = `https://api.github.com/repos/${spec.source}/contents/${skillPath}?ref=${sha}`;
  let response: Response;
  try {
    response = await fetchWithRetry(url, { headers: authHeaders(token) });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new ResolutionError(
      spec.source,
      `${name}: verifying skillPath "${skillPath}" failed: ${detail}`,
    );
  }

  if (response.status === 404) {
    throw new ResolutionError(
      spec.source,
      `${name}: skillPath "${skillPath}" does not exist at ${sha}`,
    );
  }
  if (!response.ok) {
    throw new ResolutionError(
      spec.source,
      `${name}: verifying skillPath "${skillPath}" returned HTTP ${response.status}`,
    );
  }

  return { kind: spec.kind, source: spec.source, version: sha };
}
