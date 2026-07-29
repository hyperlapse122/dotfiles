import { afterEach, describe, expect, test } from "vite-plus/test";
import {
  fetchManifestDigest,
  parseBearerChallenge,
  parseImageSource,
  resolveOciImage,
  ResolutionError,
} from "../src/oci-image.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

const SHA = "b".repeat(64);
const DIGEST = `sha256:${SHA}`;

afterEach(() => {
  globalThis.fetch = realFetch;
});

function manifestResponse(status: number, digest?: string, challenge?: string): Response {
  const headers = new Headers();
  if (digest) headers.set("docker-content-digest", digest);
  if (challenge) headers.set("www-authenticate", challenge);
  return new Response("{}", { status, headers });
}

const DOCKER_CHALLENGE =
  'Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:eceasy/cli-proxy-api:pull"';
const GHCR_CHALLENGE =
  'Bearer realm="https://ghcr.io/token",scope="repository:seakee/cpa-manager-plus:pull"';

function stubTokenThenManifest(challenge: string, digest = DIGEST): typeof globalThis.fetch {
  const calls: string[] = [];
  return (async (input: RequestInfo | URL): Promise<Response> => {
    const url = String(input);
    calls.push(url);
    if (url.includes("/token")) {
      return new Response(JSON.stringify({ token: "stub-token" }), { status: 200 });
    }
    // First manifest call is unauthenticated, the retry carries the token —
    // the stub distinguishes them by how many manifest calls it has seen.
    const manifestCalls = calls.filter((call) => call.includes("/manifests/")).length;
    if (manifestCalls === 1) return manifestResponse(401, undefined, challenge);
    return manifestResponse(200, digest);
  }) as typeof globalThis.fetch;
}

describe("parseImageSource", () => {
  test("docker.io maps to the registry-1 API host", () => {
    expect(parseImageSource("docker.io/eceasy/cli-proxy-api")).toEqual({
      host: "registry-1.docker.io",
      repository: "eceasy/cli-proxy-api",
    });
  });

  test("other registries keep their host verbatim", () => {
    expect(parseImageSource("ghcr.io/seakee/cpa-manager-plus")).toEqual({
      host: "ghcr.io",
      repository: "seakee/cpa-manager-plus",
    });
  });

  test("a source without a repository path is an error", () => {
    expect(() => parseImageSource("no-slash")).toThrow(ResolutionError);
    expect(() => parseImageSource("/repo")).toThrow(ResolutionError);
    expect(() => parseImageSource("host/")).toThrow(ResolutionError);
  });
});

describe("parseBearerChallenge", () => {
  test("extracts realm, service, and scope", () => {
    expect(parseBearerChallenge(DOCKER_CHALLENGE)).toEqual({
      realm: "https://auth.docker.io/token",
      params: {
        realm: "https://auth.docker.io/token",
        service: "registry.docker.io",
        scope: "repository:eceasy/cli-proxy-api:pull",
      },
    });
  });

  test("non-Bearer and realm-less challenges yield null", () => {
    expect(parseBearerChallenge(null)).toBeNull();
    expect(parseBearerChallenge('Basic realm="x"')).toBeNull();
    expect(parseBearerChallenge('Bearer service="x"')).toBeNull();
  });
});

describe("fetchManifestDigest", () => {
  test("Docker Hub flow: challenge, token with service+scope, digest header", async () => {
    const urls: string[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      urls.push(url);
      if (url.startsWith("https://auth.docker.io/token")) {
        return new Response(JSON.stringify({ token: "stub-token" }), { status: 200 });
      }
      if (urls.filter((u) => u.includes("/manifests/")).length === 1) {
        return manifestResponse(401, undefined, DOCKER_CHALLENGE);
      }
      return manifestResponse(200, DIGEST);
    }) as typeof globalThis.fetch;

    const digest = await fetchManifestDigest("docker.io/eceasy/cli-proxy-api", "latest");

    expect(digest).toBe(DIGEST);
    expect(urls[0]).toBe("https://registry-1.docker.io/v2/eceasy/cli-proxy-api/manifests/latest");
    const tokenTarget = urls[1];
    expect(tokenTarget).toBeDefined();
    const tokenUrl = new URL(tokenTarget as string);
    expect(tokenUrl.searchParams.get("service")).toBe("registry.docker.io");
    expect(tokenUrl.searchParams.get("scope")).toBe("repository:eceasy/cli-proxy-api:pull");
  });

  test("GHCR flow: token endpoint on the registry host itself", async () => {
    const urls: string[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      urls.push(url);
      if (url.startsWith("https://ghcr.io/token")) {
        return new Response(JSON.stringify({ access_token: "stub-token" }), { status: 200 });
      }
      if (urls.filter((u) => u.includes("/manifests/")).length === 1) {
        return manifestResponse(401, undefined, GHCR_CHALLENGE);
      }
      return manifestResponse(200, DIGEST);
    }) as typeof globalThis.fetch;

    const digest = await fetchManifestDigest("ghcr.io/seakee/cpa-manager-plus", "latest");

    expect(digest).toBe(DIGEST);
    expect(urls[0]).toBe("https://ghcr.io/v2/seakee/cpa-manager-plus/manifests/latest");
  });

  test("a manifest list digest is recorded verbatim, lowercased", async () => {
    globalThis.fetch = (async () =>
      manifestResponse(200, `sha256:${"B".repeat(64)}`)) as typeof globalThis.fetch;

    await expect(fetchManifestDigest("ghcr.io/owner/repo", "latest")).resolves.toBe(DIGEST);
  });

  test("an unpublished tag is a hard error", async () => {
    globalThis.fetch = (async () => manifestResponse(404)) as typeof globalThis.fetch;

    await expect(fetchManifestDigest("ghcr.io/owner/repo", "nope")).rejects.toThrow(
      /tag "nope" is not published/,
    );
  });

  test("a non-Bearer 401 challenge is an error, not a silent retry", async () => {
    globalThis.fetch = (async () =>
      manifestResponse(401, undefined, 'Basic realm="x"')) as typeof globalThis.fetch;

    await expect(fetchManifestDigest("ghcr.io/owner/repo", "latest")).rejects.toThrow(
      ResolutionError,
    );
  });

  test("a 200 without a usable digest header is an error", async () => {
    globalThis.fetch = (async () => manifestResponse(200)) as typeof globalThis.fetch;

    await expect(fetchManifestDigest("ghcr.io/owner/repo", "latest")).rejects.toThrow(
      /no usable digest/,
    );
  });
});

describe("resolveOciImage", () => {
  test("records the tracked tag as version and the digest, platform-free", async () => {
    globalThis.fetch = stubTokenThenManifest(GHCR_CHALLENGE);
    const spec: ToolSpec = {
      kind: "ociImage",
      source: "ghcr.io/seakee/cpa-manager-plus",
      tag: "latest",
    };

    const locked = await resolveOciImage("cpa-manager-plus", spec);

    expect(locked).toEqual({
      kind: "ociImage",
      source: "ghcr.io/seakee/cpa-manager-plus",
      version: "latest",
      digest: DIGEST,
    });
    expect(locked.artifacts).toBeUndefined();
  });

  test("a spec without a tag is an error", async () => {
    const spec: ToolSpec = { kind: "ociImage", source: "ghcr.io/owner/repo" };

    await expect(resolveOciImage("tool", spec)).rejects.toThrow(/requires a tag/);
  });
});
