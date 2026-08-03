import { compare, valid } from "semver";
import { authHeaders } from "./github.js";
import { ResolutionError } from "./types.js";
import type { LockedSkillCollection, ToolSpec } from "./types.js";

export { ResolutionError };

const API_ROOT = "https://api.github.com";
const COMMIT_SHA = /^[0-9a-f]{40}$/;
const RELEASE_SUBJECT = /^Skills v([^\s]+) \(#\d+\)$/;
const SKILL_NAME = /^figma-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;
const REGULAR_BLOB_MODES: Readonly<Record<string, true>> = { "100644": true, "100755": true };
const WINDOWS_RESERVED =
  /^(?:con|prn|aux|nul|com(?:[1-9¹²³])|lpt(?:[1-9¹²³]))(?:\..*)?$/iu;
const WINDOWS_INVALID = /[<>:"\\|?*\u0000-\u001f\uD800-\uDFFF]/u;

interface CommitCandidate {
  readonly sha: string;
  readonly version: string;
}

interface GitHubTreeEntry {
  readonly path: string;
  readonly mode: string;
  readonly type: string;
}

async function fetchJson(
  source: string,
  url: string,
  label: string,
  token: string | undefined,
): Promise<{ readonly value: unknown; readonly response: Response }> {
  let response: Response;
  try {
    response = await fetch(url, { headers: authHeaders(token) });
  } catch (error) {
    throw new ResolutionError(
      source,
      `${label} request failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (!response.ok) {
    throw new ResolutionError(source, `${label} returned HTTP ${response.status}`);
  }
  try {
    return { value: await response.json(), response };
  } catch (error) {
    throw new ResolutionError(
      source,
      `${label} returned malformed JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}


function nextPage(link: string | null): string | null {
  if (!link) return null;
  for (const part of link.split(",")) {
    const match = /^\s*<([^>]+)>\s*;(?:\s*[^,;]+;)*\s*rel="([^"]+)"\s*$/.exec(part);
    if (match?.[2]?.split(/\s+/).includes("next")) return match[1] ?? null;
  }
  return null;
}

function parseCandidate(value: unknown): CommitCandidate | null {
  if (!value || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  if (!COMMIT_SHA.test(typeof record["sha"] === "string" ? record["sha"] : "")) return null;
  const commit = record["commit"];
  if (!commit || typeof commit !== "object") return null;
  const message = (commit as Record<string, unknown>)["message"];
  if (typeof message !== "string") return null;
  const subject = message.split(/\r?\n/, 1)[0] ?? "";
  const match = RELEASE_SUBJECT.exec(subject);
  if (!match) return null;
  const normalized = valid(match[1] ?? "", { loose: false });
  return normalized ? { sha: record["sha"] as string, version: normalized } : null;
}

async function fetchCandidates(source: string, token: string | undefined): Promise<CommitCandidate[]> {
  let url: string | null = `${API_ROOT}/repos/${source}/commits?path=skills%2F&per_page=100`;
  const candidates: CommitCandidate[] = [];
  const visited = new Set<string>();
  while (url) {
    if (visited.has(url)) throw new ResolutionError(source, "commit pagination contains a cycle");
    visited.add(url);
    const page = await fetchJson(source, url, "commits", token);
    if (!Array.isArray(page.value)) {
      throw new ResolutionError(source, "commits response is not a list");
    }
    for (const value of page.value) {
      const candidate = parseCandidate(value);
      if (candidate) candidates.push(candidate);
    }
    url = nextPage(page.response.headers.get("link"));
  }
  return candidates;
}

function selectCandidate(source: string, evidence: readonly CommitCandidate[]): CommitCandidate {
  if (evidence.length === 0) {
    throw new ResolutionError(source, "no commit has an exact valid Skills v<semver> (#<number>) subject");
  }

  let highest = evidence[0]!;
  for (const candidate of evidence.slice(1)) {
    if (compare(candidate.version, highest.version) > 0) highest = candidate;
  }

  const tied = evidence.filter((candidate) => compare(candidate.version, highest.version) === 0);
  const distinctShas = [...new Set(tied.map((candidate) => candidate.sha))];
  if (distinctShas.length > 1) {
    throw new ResolutionError(
      source,
      `ambiguous highest semantic version ${highest.version} appears on distinct commits`,
    );
  }

  return tied.find((candidate) => candidate.sha === distinctShas[0])!;
}

function parseTreeEntry(source: string, value: unknown): GitHubTreeEntry {
  if (!value || typeof value !== "object") {
    throw new ResolutionError(source, "selected tree contains a malformed entry");
  }
  const record = value as Record<string, unknown>;
  if (
    typeof record["path"] !== "string" ||
    typeof record["mode"] !== "string" ||
    typeof record["type"] !== "string"
  ) {
    throw new ResolutionError(source, "selected tree contains a malformed entry");
  }
  return { path: record["path"], mode: record["mode"], type: record["type"] };
}

function validateComponent(source: string, component: string, path: string): void {
  if (
    component.length === 0 ||
    component === "." ||
    component === ".." ||
    component.endsWith(".") ||
    component.endsWith(" ") ||
    Buffer.byteLength(component, "utf8") > 255 ||
    component.normalize("NFC") !== component ||
    WINDOWS_INVALID.test(component) ||
    WINDOWS_RESERVED.test(component)
  ) {
    throw new ResolutionError(source, `selected tree path is not portable: ${path}`);
  }
}

function validateSelectedPath(source: string, path: string): void {
  if (path.startsWith("/") || path.includes("\\")) {
    throw new ResolutionError(source, `selected tree path is unsafe: ${path}`);
  }
  const components = path.split("/");
  for (const component of components) validateComponent(source, component, path);
}

function isRegularEntry(entry: GitHubTreeEntry): boolean {
  return entry.type === "blob" && REGULAR_BLOB_MODES[entry.mode] === true;
}

function inventorySkills(source: string, values: readonly unknown[]): string[] {
  const entries = values.map((value) => parseTreeEntry(source, value));
  const skills: string[] = [];

  for (const entry of entries) {
    const match = /^skills\/([^/]+)$/.exec(entry.path);
    if (!match) continue;
    const name = match[1]!;
    if (!name.startsWith("figma-")) continue;
    if (!SKILL_NAME.test(name)) {
      throw new ResolutionError(source, `unsafe Figma skill name: ${name}`);
    }
    if (entry.type === "tree" && entry.mode === "040000") skills.push(name);
  }

  const sortedSkills = [...skills].sort((a, b) => a.localeCompare(b));
  if (sortedSkills.length === 0) {
    throw new ResolutionError(source, "selected tree contains no valid immediate figma-* skill directories");
  }
  if (new Set(sortedSkills).size !== sortedSkills.length) {
    throw new ResolutionError(source, "selected tree contains duplicate Figma skill directories");
  }

  const selectedPaths = new Map<string, string>();
  const hasSkillFile = new Set<string>();
  for (const entry of entries) {
    const skill = sortedSkills.find(
      (name) => entry.path === `skills/${name}` || entry.path.startsWith(`skills/${name}/`),
    );
    if (!skill) continue;

    validateSelectedPath(source, entry.path);
    const folded = entry.path.toLowerCase();
    const existing = selectedPaths.get(folded);
    if (existing) {
      const detail = existing === entry.path ? "duplicate" : "case-colliding";
      throw new ResolutionError(source, `selected tree contains ${detail} path: ${entry.path}`);
    }
    selectedPaths.set(folded, entry.path);

    const supportedTree = entry.type === "tree" && entry.mode === "040000";
    if (!supportedTree && !isRegularEntry(entry)) {
      throw new ResolutionError(
        source,
        `selected tree contains unsupported entry ${entry.path} (${entry.mode} ${entry.type})`,
      );
    }
    if (entry.path === `skills/${skill}/SKILL.md` && isRegularEntry(entry)) {
      hasSkillFile.add(skill);
    }
  }

  for (const skill of sortedSkills) {
    if (!hasSkillFile.has(skill)) {
      throw new ResolutionError(source, `${skill} is missing a regular SKILL.md file`);
    }
  }
  return sortedSkills;
}

async function fetchInventory(
  source: string,
  revision: string,
  token: string | undefined,
): Promise<string[]> {
  const result = await fetchJson(
    source,
    `${API_ROOT}/repos/${source}/git/trees/${revision}?recursive=1`,
    "selected tree",
    token,
  );
  if (!result.value || typeof result.value !== "object") {
    throw new ResolutionError(source, "selected tree response is malformed");
  }
  const record = result.value as Record<string, unknown>;
  if (record["truncated"] === true) {
    throw new ResolutionError(source, "selected tree response is truncated");
  }
  if (record["truncated"] !== false || !Array.isArray(record["tree"])) {
    throw new ResolutionError(source, "selected tree response is malformed");
  }
  return inventorySkills(source, record["tree"]);
}

/** Resolve the highest authoritative Figma skills commit into one immutable collection entry. */
export async function resolveGitHubSkillCollection(
  _name: string,
  spec: ToolSpec,
  token: string | undefined,
): Promise<LockedSkillCollection> {
  const selected = selectCandidate(spec.source, await fetchCandidates(spec.source, token));
  const skills = await fetchInventory(spec.source, selected.sha, token);
  return {
    kind: "githubSkillCollection",
    source: spec.source,
    version: selected.version,
    revision: selected.sha,
    skills,
  };
}
