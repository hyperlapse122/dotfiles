import { afterEach, describe, expect, test } from "vite-plus/test";
import { normalizeDigest, resolveGitHubRelease, ResolutionError } from "../src/github.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

interface StubAsset {
  name: string;
  browser_download_url: string;
  digest?: string | null;
}

function stubRelease(tagName: string, assets: StubAsset[]): void {
  globalThis.fetch = (async () =>
    new Response(JSON.stringify({ tag_name: tagName, assets }), {
      status: 200,
      headers: { "content-type": "application/json" },
    })) as typeof globalThis.fetch;
}

function asset(name: string, digest?: string | null): StubAsset {
  const entry: StubAsset = {
    name,
    browser_download_url: `https://example.invalid/download/${name}`,
  };
  if (digest !== undefined) entry.digest = digest;
  return entry;
}

const SHA = "a".repeat(64);

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("normalizeDigest", () => {
  test("accepts a sha256-prefixed lowercase hex digest", () => {
    expect(normalizeDigest(`sha256:${SHA}`)).toBe(SHA);
  });

  test("uppercases are normalized to lowercase hex", () => {
    expect(normalizeDigest(`sha256:${"A".repeat(64)}`)).toBe(SHA);
  });

  test("absent, wrongly-prefixed, or malformed digests yield null rather than a bad value", () => {
    expect(normalizeDigest(null)).toBeNull();
    expect(normalizeDigest(undefined)).toBeNull();
    expect(normalizeDigest(SHA)).toBeNull();
    expect(normalizeDigest("sha512:" + "a".repeat(128))).toBeNull();
    expect(normalizeDigest("sha256:nothex")).toBeNull();
  });
});

describe("resolveGitHubRelease", () => {
  const spec = (overrides: Partial<ToolSpec> = {}): ToolSpec => ({
    kind: "githubRelease",
    source: "owner/repo",
    asset: ({ os, arch }) => `tool-${os}-${arch}`,
    ...overrides,
  });

  test("records url and digest for every targeted platform", async () => {
    stubRelease("v1.2.3", [
      asset("tool-linux-amd64", `sha256:${SHA}`),
      asset("tool-linux-arm64", `sha256:${SHA}`),
      asset("tool-darwin-amd64", `sha256:${SHA}`),
      asset("tool-darwin-arm64", `sha256:${SHA}`),
      asset("tool-windows-amd64", `sha256:${SHA}`),
      asset("tool-windows-arm64", `sha256:${SHA}`),
    ]);

    const locked = await resolveGitHubRelease("tool", spec(), undefined);

    expect(locked.version).toBe("v1.2.3");
    expect(Object.keys(locked.artifacts ?? {})).toHaveLength(6);
    expect(locked.artifacts?.["darwin-arm64"]).toEqual({
      url: "https://example.invalid/download/tool-darwin-arm64",
      sha256: SHA,
    });
  });

  test("an asset without a digest records a null sha256 but keeps its url", async () => {
    stubRelease("v1", [asset("tool-linux-amd64")]);

    const locked = await resolveGitHubRelease(
      "tool",
      spec({
        asset: ({ os, arch }) => (os === "linux" && arch === "amd64" ? `tool-${os}-${arch}` : null),
      }),
      undefined,
    );

    expect(locked.artifacts?.["linux-amd64"]?.sha256).toBeNull();
    expect(locked.artifacts?.["linux-amd64"]?.url).toContain("tool-linux-amd64");
  });

  test("a selector returning null skips that platform without failing", async () => {
    stubRelease("v1", [asset("tool-darwin-arm64", `sha256:${SHA}`)]);

    const locked = await resolveGitHubRelease(
      "tool",
      spec({
        asset: ({ os, arch }) => (os === "darwin" && arch === "arm64" ? "tool-darwin-arm64" : null),
      }),
      undefined,
    );

    expect(Object.keys(locked.artifacts ?? {})).toEqual(["darwin-arm64"]);
  });

  test("a declared emulated platform borrows the amd64 artifact and is marked", async () => {
    stubRelease("v1", [asset("tool-windows-amd64", `sha256:${SHA}`)]);

    const locked = await resolveGitHubRelease(
      "tool",
      spec({
        asset: ({ os, arch }) => (os === "windows" ? `tool-${os}-${arch}` : null),
        emulatedPlatforms: ["windows-arm64"],
      }),
      undefined,
    );

    expect(locked.artifacts?.["windows-arm64"]).toEqual({
      url: "https://example.invalid/download/tool-windows-amd64",
      sha256: SHA,
      emulated: true,
    });
    expect(locked.artifacts?.["windows-amd64"]?.emulated).toBeUndefined();
  });

  test("a named asset the release does not publish is a hard error, not a silent skip", async () => {
    stubRelease("v9", [asset("some-other-name", `sha256:${SHA}`)]);

    await expect(resolveGitHubRelease("tool", spec(), undefined)).rejects.toBeInstanceOf(
      ResolutionError,
    );
  });

  test("a version-only tool emits no artifacts block", async () => {
    stubRelease("2026-07-20", []);

    const locked = await resolveGitHubRelease(
      "tool",
      { kind: "githubRelease", source: "owner/repo" },
      undefined,
    );

    expect(locked.version).toBe("2026-07-20");
    expect(locked.artifacts).toBeUndefined();
  });

  test("a non-200 response fails with the source named", async () => {
    globalThis.fetch = (async () =>
      new Response("nope", { status: 404 })) as typeof globalThis.fetch;

    await expect(resolveGitHubRelease("tool", spec(), undefined)).rejects.toThrow(/owner\/repo/);
  });
});
