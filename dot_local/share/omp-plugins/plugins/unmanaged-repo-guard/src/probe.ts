/**
 * Fail-closed access probe with an identity-bound cache (plan U3).
 *
 * Answers "does the user manage this repository?" definitively or not at all.
 * Anything the probe cannot decide is `indeterminate`, which blocks (plan R3).
 */

import type { BoundedExec } from "./exec.ts";
import type { RepoRef } from "./target.ts";
import { isValidRepoPath } from "./target.ts";

export type Verdict = "managed" | "unmanaged" | "indeterminate";

export type ProbeOutcome = {
  verdict: Verdict;
  /** Short, quotable reason: the permission value, or why the probe failed. */
  detail: string;
  /** The candidate the verdict is about. */
  repo: string;
};

export type ProberOptions = {
  exec: BoundedExec;
  now: () => number;
  cacheTtlMs: number;
};

const MANAGED_GITHUB_PERMISSIONS: Record<string, true> = {
  ADMIN: true,
  MAINTAIN: true,
  WRITE: true,
};

const GITLAB_MIN_ACCESS_LEVEL = 30;

type CacheEntry = {
  verdict: Exclude<Verdict, "indeterminate">;
  detail: string;
  expiresAt: number;
  /** The resolved fork parent, if any, so a cache hit can still re-queue it (plan R9). */
  parent: RepoRef | null;
};

type IdentityEntry = {
  value: string | null;
  expiresAt: number;
};

type RawProbe = { ok: true; json: Record<string, unknown> } | { ok: false; detail: string };

export function createProber(options: ProberOptions) {
  const { exec, now, cacheTtlMs } = options;

  // Dynamic, runtime-populated collections with expiry: Map, not Record.
  const verdicts = new Map<string, CacheEntry>();
  const identities = new Map<string, IdentityEntry>();

  async function identityFor(ref: RepoRef): Promise<string | null> {
    const key = `${ref.hostKind}|${ref.host}`;
    const cached = identities.get(key);
    if (cached && cached.expiresAt > now()) return cached.value;

    const result =
      ref.hostKind === "github"
        ? await exec("gh", ["api", "--hostname", ref.host, "user", "--jq", ".login"])
        : await exec("glab", ["api", "--hostname", ref.host, "user"]);

    let value: string | null = null;
    if (result !== null && result.code === 0 && !result.killed) {
      const text = result.stdout.trim();
      if (ref.hostKind === "github") {
        value = text === "" ? null : text;
      } else {
        try {
          const parsed: unknown = JSON.parse(text);
          const username =
            typeof parsed === "object" && parsed !== null
              ? (parsed as Record<string, unknown>)["username"]
              : null;
          value = typeof username === "string" ? username : null;
        } catch {
          value = null;
        }
      }
    }
    identities.set(key, { value, expiresAt: now() + cacheTtlMs });
    return value;
  }

  async function rawProbe(ref: RepoRef): Promise<RawProbe> {
    const command = ref.hostKind === "github" ? "gh" : "glab";
    const args =
      ref.hostKind === "github"
        ? [
            "repo",
            "view",
            ref.host === "github.com" ? ref.path : `${ref.host}/${ref.path}`,
            "--json",
            "viewerPermission,isFork,parent",
          ]
        : ["api", "--hostname", ref.host, `projects/${encodeURIComponent(ref.path)}`];

    const result = await exec(command, args);
    if (result === null) return { ok: false, detail: `${command} probe timed out` };
    if (result.killed) return { ok: false, detail: `${command} probe was cancelled` };
    if (result.code !== 0) {
      const stderr = result.stderr.trim().split("\n")[0] ?? "";
      return {
        ok: false,
        detail: `${command} exited ${result.code}${stderr ? `: ${summarize(stderr)}` : ""}`,
      };
    }
    try {
      const parsed: unknown = JSON.parse(result.stdout);
      if (typeof parsed !== "object" || parsed === null) {
        return { ok: false, detail: `${command} returned a non-object response` };
      }
      return { ok: true, json: parsed as Record<string, unknown> };
    } catch {
      return { ok: false, detail: `${command} returned unparseable JSON` };
    }
  }

  /** Verdict for one repository, plus the fork parent to probe next, if any. */
  async function probeOne(ref: RepoRef): Promise<{ outcome: ProbeOutcome; parent: RepoRef | null }> {
    const cli = ref.hostKind === "github" ? "gh" : "glab";
    const undecided = (detail: string) => ({
      outcome: { verdict: "indeterminate" as const, detail, repo: ref.path },
      parent: null,
    });

    const identity = await identityFor(ref);
    // The identity comes from the host's own JSON, so it is encoded rather than
    // interpolated raw: an identity containing the delimiter must not be able
    // to collide with another identity's cache entry (plan R16).
    const key = `${encodeURIComponent(identity ?? "anonymous")}|${ref.hostKind}|${ref.host}|${ref.path}`;
    const cached = verdicts.get(key);
    if (cached && cached.expiresAt > now()) {
      return {
        outcome: { verdict: cached.verdict, detail: cached.detail, repo: ref.path },
        parent: cached.parent,
      };
    }

    const raw = await rawProbe(ref);
    if (!raw.ok) return undecided(raw.detail);

    let verdict: Exclude<Verdict, "indeterminate">;
    let detail: string;
    // `undefined` means not a fork; `null` means a fork whose parent could not
    // be read, which leaves R10 unanswered and therefore blocks.
    let parentPath: string | null | undefined;

    if (ref.hostKind === "github") {
      const permission = raw.json["viewerPermission"];
      if (typeof permission !== "string") return undecided("gh omitted viewerPermission");
      verdict =
        MANAGED_GITHUB_PERMISSIONS[permission.toUpperCase()] === true ? "managed" : "unmanaged";
      detail = `viewerPermission=${permission}`;
      if (raw.json["isFork"] === true) parentPath = readGithubParent(raw.json["parent"]);
    } else {
      const level = readGitlabAccessLevel(raw.json["permissions"]);
      if (level === undefined) return undecided("glab omitted permissions");
      verdict = level >= GITLAB_MIN_ACCESS_LEVEL ? "managed" : "unmanaged";
      detail = `access_level=${level}`;
      const forkNode = raw.json["forked_from_project"];
      if (forkNode !== null && forkNode !== undefined) {
        const candidate =
          typeof forkNode === "object"
            ? (forkNode as Record<string, unknown>)["path_with_namespace"]
            : null;
        parentPath = typeof candidate === "string" ? candidate : null;
      }
    }

    // A fork whose parent cannot be read — or whose parent fails validation, so
    // it can never be probed — leaves R10 unanswered, which blocks.
    if (parentPath === null) return undecided(`${cli} reported a fork without a resolvable parent`);
    let parent: RepoRef | null = null;
    if (parentPath !== undefined) {
      if (!isValidRepoPath(parentPath, ref.hostKind)) {
        return undecided(`${cli} reported a fork parent that failed validation`);
      }
      parent = { host: ref.host, hostKind: ref.hostKind, path: parentPath };
    }

    // Clamp the verdict to the identity entry that keyed it. The identity
    // cache is per host while this one is per repository, so a second repo
    // probed later on the same host would otherwise outlive the shared
    // identity and pay a redundant identity subprocess on its own cache hit.
    // Clamping makes "a live verdict always has a live identity" true by
    // construction, and can only shorten a verdict's life (plan R6, KTD3).
    const identityEntry = identities.get(`${ref.hostKind}|${ref.host}`);
    const expiresAt = Math.min(
      now() + cacheTtlMs,
      identityEntry ? identityEntry.expiresAt : now() + cacheTtlMs,
    );
    verdicts.set(key, { verdict, detail, expiresAt, parent });
    return { outcome: { verdict, detail, repo: ref.path }, parent };
  }

  return {
    /**
     * Evaluate every candidate, including any fork parent discovered on the
     * way. The first non-`managed` outcome decides the call (plan R10).
     */
    async evaluate(candidates: RepoRef[]): Promise<ProbeOutcome> {
      if (candidates.length === 0) {
        return {
          verdict: "indeterminate",
          detail: "no target repository could be resolved",
          repo: "unknown",
        };
      }
      const queue = [...candidates];
      const seen = new Set<string>();
      let last: ProbeOutcome | null = null;

      while (queue.length > 0) {
        const ref = queue.shift() as RepoRef;
        const dedupeKey = `${ref.hostKind}|${ref.host}|${ref.path}`;
        if (seen.has(dedupeKey)) continue;
        seen.add(dedupeKey);

        const { outcome, parent } = await probeOne(ref);
        if (outcome.verdict !== "managed") return outcome;
        last = outcome;
        if (parent) queue.push(parent);
      }

      return last ?? { verdict: "indeterminate", detail: "no candidate was probed", repo: "unknown" };
    },
  };
}

/**
 * Bound and flatten CLI stderr before it reaches the agent-facing reason string,
 * so an unexpectedly chatty error line cannot dump request metadata into output.
 */
function summarize(stderr: string): string {
  return stderr.replace(/\s+/g, " ").slice(0, 120);
}

function readGithubParent(node: unknown): string | null {
  if (typeof node !== "object" || node === null) return null;
  const parent = node as Record<string, unknown>;
  const nameWithOwner = parent["nameWithOwner"];
  if (typeof nameWithOwner === "string") return nameWithOwner;
  const name = parent["name"];
  const owner = parent["owner"];
  const login =
    typeof owner === "object" && owner !== null ? (owner as Record<string, unknown>)["login"] : null;
  if (typeof name === "string" && typeof login === "string") return `${login}/${name}`;
  return null;
}

function readGitlabAccessLevel(node: unknown): number | undefined {
  if (typeof node !== "object" || node === null) return undefined;
  const permissions = node as Record<string, unknown>;
  let best = -1;
  let sawKey = false;
  for (const key of ["project_access", "group_access"]) {
    if (!(key in permissions)) continue;
    sawKey = true;
    const scope = permissions[key];
    if (typeof scope !== "object" || scope === null) continue;
    const level = (scope as Record<string, unknown>)["access_level"];
    if (typeof level === "number" && level > best) best = level;
  }
  if (!sawKey) return undefined;
  return best < 0 ? 0 : best;
}
