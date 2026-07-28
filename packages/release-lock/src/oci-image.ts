import { ResolutionError } from "./types.js";
import type { LockedTool, ToolSpec } from "./types.js";

export { ResolutionError };

/**
 * OCI image resolution — a registry/repository tag resolved to its manifest
 * digest through the registry HTTP API, never by pulling the image. The
 * digest is platform-free: pinning a multi-arch manifest list covers every
 * platform at once, so no artifacts block is emitted.
 *
 * Authentication is the standard anonymous Bearer-token dance: request the
 * manifest, and on a 401 challenge fetch a pull-scope token from the
 * advertised realm (auth.docker.io for Docker Hub, ghcr.io/token for GHCR).
 * The refresh token parameter is the GitHub one and is not used here.
 */

const MANIFEST_ACCEPT = [
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
].join(", ");

const USER_AGENT = "h82-release-lock";

/** Split `registry/repository` into the API host and repository path. */
export function parseImageSource(source: string): { host: string; repository: string } {
  const slash = source.indexOf("/");
  if (slash <= 0 || slash === source.length - 1) {
    throw new ResolutionError(source, `expected "registry/repository", got "${source}"`);
  }
  const host = source.slice(0, slash);
  // Docker Hub's API endpoint differs from the registry alias users write.
  return {
    host: host === "docker.io" ? "registry-1.docker.io" : host,
    repository: source.slice(slash + 1),
  };
}

interface BearerChallenge {
  readonly realm: string;
  readonly params: Readonly<Record<string, string>>;
}

/**
 * Parse a `WWW-Authenticate: Bearer realm="...",service="...",scope="..."`
 * challenge. Returns null for anything that is not a Bearer challenge with a
 * realm — only that flow is supported.
 */
export function parseBearerChallenge(header: string | null): BearerChallenge | null {
  if (!header || !header.startsWith("Bearer ")) return null;
  const params: Record<string, string> = {};
  for (const pair of header.slice("Bearer ".length).split(",")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    const key = pair.slice(0, eq).trim();
    const value = pair
      .slice(eq + 1)
      .trim()
      .replace(/^"|"$/g, "");
    params[key] = value;
  }
  if (!params.realm) return null;
  return { realm: params.realm, params };
}

/** Fetch an anonymous pull-scope token from a challenge realm. */
async function fetchBearerToken(source: string, challenge: BearerChallenge): Promise<string> {
  const url = new URL(challenge.realm);
  for (const [key, value] of Object.entries(challenge.params)) {
    if (key !== "realm") url.searchParams.set(key, value);
  }
  const response = await fetch(url, { headers: { "user-agent": USER_AGENT } });
  if (!response.ok) {
    throw new ResolutionError(source, `token endpoint returned HTTP ${response.status}`);
  }
  const body = (await response.json()) as { token?: string; access_token?: string };
  const token = body.token ?? body.access_token;
  if (typeof token !== "string" || token === "") {
    throw new ResolutionError(source, "token endpoint response carries no token");
  }
  return token;
}

/** Resolve `repository:tag` to the digest in its `Docker-Content-Digest` header. */
export async function fetchManifestDigest(source: string, tag: string): Promise<string> {
  const { host, repository } = parseImageSource(source);
  const url = `https://${host}/v2/${repository}/manifests/${tag}`;
  const headers = { accept: MANIFEST_ACCEPT, "user-agent": USER_AGENT };

  let response = await fetch(url, { headers });
  if (response.status === 401) {
    const challenge = parseBearerChallenge(response.headers.get("www-authenticate"));
    if (!challenge) {
      throw new ResolutionError(source, "registry demands a non-Bearer authentication flow");
    }
    const token = await fetchBearerToken(source, challenge);
    response = await fetch(url, {
      headers: { ...headers, authorization: `Bearer ${token}` },
    });
  }
  if (response.status === 404) {
    // Hard error, matching every other kind: a tag the registry does not
    // publish is a stale declaration, never a silent skip.
    throw new ResolutionError(source, `tag "${tag}" is not published`);
  }
  if (!response.ok) {
    throw new ResolutionError(source, `manifest request returned HTTP ${response.status}`);
  }

  const digest = response.headers.get("docker-content-digest");
  if (!digest || !/^sha256:[0-9a-f]{64}$/i.test(digest)) {
    throw new ResolutionError(source, `registry returned no usable digest for tag "${tag}"`);
  }
  return digest.toLowerCase();
}

export async function resolveOciImage(name: string, spec: ToolSpec): Promise<LockedTool> {
  if (!spec.tag) {
    throw new ResolutionError(spec.source, `${name}: ociImage requires a tag`);
  }
  const digest = await fetchManifestDigest(spec.source, spec.tag);
  return { kind: spec.kind, source: spec.source, version: spec.tag, digest };
}
