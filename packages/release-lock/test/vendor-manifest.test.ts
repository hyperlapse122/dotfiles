import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveVendorManifest, ResolutionError } from "../src/vendor-manifest.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

const SHA = "a".repeat(64);

/** URL-prefix routed stub; an unrouted request 404s. */
function stubRoutes(routes: Record<string, () => Response>): void {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    for (const [prefix, respond] of Object.entries(routes)) {
      if (url.startsWith(prefix)) return respond();
    }
    return new Response("not stubbed", { status: 404 });
  }) as typeof globalThis.fetch;
}

function json(body: unknown): () => Response {
  return () =>
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
}

function text(body: string): () => Response {
  return () => new Response(body, { status: 200 });
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

function claudeManifest(platforms: Record<string, unknown>): unknown {
  return { version: "2.1.220", platforms };
}

function claudePlatform(checksum = SHA, size = 123): Record<string, unknown> {
  return { binary: "claude", checksum, size };
}

function fullClaudePlatforms(): Record<string, unknown> {
  return {
    "darwin-arm64": claudePlatform(),
    "darwin-x64": claudePlatform(),
    "linux-arm64": claudePlatform(),
    "linux-arm64-musl": claudePlatform(),
    "linux-x64": claudePlatform(),
    "linux-x64-musl": claudePlatform(),
    "win32-arm64": claudePlatform(),
    "win32-x64": claudePlatform(),
  };
}

describe("resolveVendorManifest claude", () => {
  const spec: ToolSpec = {
    kind: "vendorManifest",
    vendor: "claude",
    source: "https://downloads.example.invalid/claude-code-releases",
  };

  test("maps manifest platform ids to lock keys, including the musl keys", async () => {
    stubRoutes({
      "https://downloads.example.invalid/claude-code-releases/latest": text("2.1.220"),
      "https://downloads.example.invalid/claude-code-releases/2.1.220/manifest.json": json(
        claudeManifest({
          "darwin-arm64": claudePlatform(),
          "darwin-x64": claudePlatform(),
          "linux-arm64": claudePlatform(),
          "linux-arm64-musl": claudePlatform(),
          "linux-x64": claudePlatform(),
          "linux-x64-musl": claudePlatform(),
          "win32-arm64": claudePlatform(),
          "win32-x64": claudePlatform(),
        }),
      ),
    });

    const locked = await resolveVendorManifest("claude", spec);

    expect(locked.version).toBe("2.1.220");
    expect(Object.keys(locked.artifacts ?? {}).sort()).toEqual(
      [
        "darwin-amd64",
        "darwin-arm64",
        "linux-amd64",
        "linux-amd64-musl",
        "linux-arm64",
        "linux-arm64-musl",
        "windows-amd64",
        "windows-arm64",
      ].sort(),
    );
    expect(locked.artifacts?.["linux-amd64-musl"]).toEqual({
      url: "https://downloads.example.invalid/claude-code-releases/2.1.220/linux-x64-musl/claude",
      sha256: SHA,
      size: 123,
    });
    expect(locked.artifacts?.["windows-arm64"]?.url).toContain("/win32-arm64/");
  });

  test("a manifest platform id the mapping does not know is a hard error", async () => {
    stubRoutes({
      "https://downloads.example.invalid/claude-code-releases/latest": text("2.1.220"),
      "https://downloads.example.invalid/claude-code-releases/2.1.220/manifest.json": json(
        claudeManifest({ "linux-riscv64": claudePlatform() }),
      ),
    });

    const error = await resolveVendorManifest("claude", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/downloads\.example\.invalid/);
  });

  test("a known platform missing from the manifest is a hard error, never a silent skip", async () => {
    const platforms = fullClaudePlatforms();
    delete platforms["win32-arm64"];
    stubRoutes({
      "https://downloads.example.invalid/claude-code-releases/latest": text("2.1.220"),
      "https://downloads.example.invalid/claude-code-releases/2.1.220/manifest.json": json(
        claudeManifest(platforms),
      ),
    });

    const error = await resolveVendorManifest("claude", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/missing known platform id "win32-arm64"/);
  });

  test("a manifest missing version or platforms is a hard error", async () => {
    stubRoutes({
      "https://downloads.example.invalid/claude-code-releases/latest": text("2.1.220"),
      "https://downloads.example.invalid/claude-code-releases/2.1.220/manifest.json": json({}),
    });

    const error = await resolveVendorManifest("claude", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/missing version or platforms/);
  });

  test("a malformed checksum is recorded as a null sha256 while the URL is kept", async () => {
    const platforms = fullClaudePlatforms();
    platforms["linux-x64"] = claudePlatform("not-a-digest");
    stubRoutes({
      "https://downloads.example.invalid/claude-code-releases/latest": text("2.1.220"),
      "https://downloads.example.invalid/claude-code-releases/2.1.220/manifest.json": json(
        claudeManifest(platforms),
      ),
    });

    const locked = await resolveVendorManifest("claude", spec);

    expect(locked.artifacts?.["linux-amd64"]).toEqual({
      url: "https://downloads.example.invalid/claude-code-releases/2.1.220/linux-x64/claude",
      sha256: null,
      size: 123,
    });
  });

  test("a failed latest endpoint fails with the source named", async () => {
    stubRoutes({});

    await expect(resolveVendorManifest("claude", spec)).rejects.toThrow(
      /downloads\.example\.invalid/,
    );
  });
});

test("rejects the retired antigravity vendor as unknown", async () => {
  const spec = {
    kind: "vendorManifest",
    vendor: "antigravity",
    source: "https://agy.example.invalid/manifests",
  } as unknown as ToolSpec;

  await expect(resolveVendorManifest("agy", spec)).rejects.toThrow('unknown vendor "antigravity"');
});

describe("resolveVendorManifest winbox", () => {
  const spec: ToolSpec = {
    kind: "vendorManifest",
    vendor: "winbox",
    source: "https://download.example.invalid/routeros/winbox/LATEST.4",
  };

  test("records the bare version string, trimmed, version-only", async () => {
    stubRoutes({ "https://download.example.invalid/routeros/winbox/LATEST.4": text("4.3\n") });

    const locked = await resolveVendorManifest("winbox", spec);

    expect(locked.version).toBe("4.3");
    expect(locked.artifacts).toBeUndefined();
  });

  test("a response that is not a version fails with the source named", async () => {
    stubRoutes({
      "https://download.example.invalid/routeros/winbox/LATEST.4": text("<html>oops</html>"),
    });

    const error = await resolveVendorManifest("winbox", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/download\.example\.invalid/);
  });
});
