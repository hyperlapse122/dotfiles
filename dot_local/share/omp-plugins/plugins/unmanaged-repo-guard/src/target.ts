/**
 * Target and host resolution (plan U2).
 *
 * Produces the repositories a classified call would actually write to. Every
 * identifier is validated before it can reach a subprocess or a URL (plan R15):
 * the value originates in a model-authored command string, so the guard's own
 * probe must not become the injection point.
 */

import type { BoundedExec } from "./exec.ts";
import type { Classification, HostKind } from "./triggers.ts";

export type RepoRef = { host: string; hostKind: HostKind; path: string };

export type ResolveResult = {
  candidates: RepoRef[];
  /** An identifier was present but failed validation, or none could be found. */
  invalid: boolean;
};

const DEFAULT_HOST: Record<HostKind, string> = {
  github: "github.com",
  gitlab: "gitlab.com",
};

/** `owner/repo`, no path traversal, no leading `-` that could read as a flag. */
const GITHUB_PATH = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;

/** GitLab allows nested subgroups: `group/subgroup/project`. */
const GITLAB_PATH = /^[A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*){1,20}$/;

/** Hostnames only: no scheme, no credentials, no path, no shell metacharacters. */
const HOSTNAME =
  /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*$/;

/** A bracketed IPv6 literal, as git's own scp-like syntax writes it. */
const IPV6_HOST = /^\[[0-9A-Fa-f:.]+\]$/;

export function isValidRepoPath(path: string, hostKind: HostKind): boolean {
  if (path === "" || path.includes("..")) return false;
  return hostKind === "github" ? GITHUB_PATH.test(path) : GITLAB_PATH.test(path);
}

export function isValidHost(host: string): boolean {
  return HOSTNAME.test(host) || IPV6_HOST.test(host);
}

/**
 * Extract host and repository path from an `origin` URL.
 *
 * Handles the shapes git remotes actually take: bracketed-IPv6 scp-style,
 * ordinary scp-style (`git@host:path`), and a URL with a scheme.
 */
export function parseRemoteUrl(url: string): { host: string; path: string } | null {
  const trimmed = url.trim();
  if (trimmed === "") return null;

  const clean = (path: string) => path.replace(/\.git$/, "").replace(/^\/+|\/+$/g, "");

  // Bracketed IPv6 must be tried first: the generic scp regex would split it
  // on its first inner colon and produce a nonsense host/path pair.
  const scpIpv6 = /^(?:[^@/\s]+@)?(\[[^\]\s]+\]):(?!\/)(.+)$/.exec(trimmed);
  if (scpIpv6) {
    const host = scpIpv6[1];
    const path = scpIpv6[2];
    if (host === undefined || path === undefined) return null;
    return { host, path: clean(path) };
  }

  const scp = /^(?:[^@/\s]+@)?([^:/\s]+):(?!\/)(.+)$/.exec(trimmed);
  if (scp) {
    const host = scp[1];
    const path = scp[2];
    if (host === undefined || path === undefined) return null;
    return { host, path: clean(path) };
  }

  const withScheme =
    /^[A-Za-z][A-Za-z0-9+.-]*:\/\/(?:[^@/\s]+@)?(\[[^\]\s]+\]|[^:/\s]+)(?::\d+)?\/(.+)$/.exec(
      trimmed,
    );
  if (withScheme) {
    const host = withScheme[1];
    const path = withScheme[2];
    if (host === undefined || path === undefined) return null;
    return { host, path: clean(path) };
  }

  return null;
}

/**
 * Resolve the candidate repositories for a classified issue write.
 *
 * An explicit `--repo`/`-R` wins over the checkout's `origin` (plan R8/R9); a
 * host named on the command wins over the remote's host (plan R11). The fork
 * parent is appended later by the probe, which is where that datum arrives.
 */
export async function resolveCandidates(
  classification: Extract<Classification, { kind: "issue-write" }>,
  cwd: string | undefined,
  exec: BoundedExec,
): Promise<ResolveResult> {
  const hostKind = classification.hostKind ?? "github";

  let path = classification.repo;
  let host = classification.host;

  if (path === null) {
    // No explicit target, so the write lands in whatever directory the command
    // actually runs in. A `cd` this classifier could not resolve makes that
    // directory unknowable, and an unknowable target must block (plan R3).
    if (classification.cwdUnresolvable) return { candidates: [], invalid: true };

    const effectiveCwd = resolveCwd(cwd, classification.cdTarget);
    const remote = await exec("git", ["remote", "get-url", "origin"], { cwd: effectiveCwd });
    if (remote === null || remote.code !== 0 || remote.stdout.trim() === "") {
      return { candidates: [], invalid: true };
    }
    const parsed = parseRemoteUrl(remote.stdout.trim());
    if (!parsed) return { candidates: [], invalid: true };
    path = parsed.path;
    host = host ?? parsed.host;
  }

  const resolvedHost = host ?? DEFAULT_HOST[hostKind];
  if (!isValidHost(resolvedHost)) return { candidates: [], invalid: true };
  if (!isValidRepoPath(path, hostKind)) return { candidates: [], invalid: true };

  return { candidates: [{ host: resolvedHost, hostKind, path }], invalid: false };
}

/** Apply a literal `cd` from the same command to the tool call's own cwd. */
function resolveCwd(cwd: string | undefined, cdTarget: string | null): string | undefined {
  if (cdTarget === null) return cwd;
  if (cdTarget.startsWith("/")) return cdTarget;
  if (cwd === undefined) return undefined;
  return `${cwd.replace(/\/+$/, "")}/${cdTarget}`;
}
