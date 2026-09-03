import { createHash } from "node:crypto";
import { afterEach, describe, expect, test } from "vite-plus/test";
import { ALL_PLATFORMS } from "../src/platforms.js";
import { resolveVendorManifest, ResolutionError } from "../src/vendor-manifest.js";
import type { ToolSpec } from "../src/types.js";
const realFetch = globalThis.fetch;

/**
 * URL-prefix routed stub; an unrouted request 404s. The returned array records
 * every requested URL in order, which is how the no-download property is proven:
 * a resolver that fetched an artifact body would show it here.
 */
function stubRoutes(routes: Record<string, () => Response>): string[] {
  const requests: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    requests.push(url);
    for (const [prefix, respond] of Object.entries(routes)) {
      if (url.startsWith(prefix)) return respond();
    }
    return new Response("not stubbed", { status: 404 });
  }) as typeof globalThis.fetch;
  return requests;
}

const SHA = "a".repeat(64);
const SHA512 = "b".repeat(128);

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
  };
}
const ONE_PASSWORD_SOURCE = "https://releases.example.invalid/linux/stable/index.xml";
const ONE_PASSWORD_FEED = `<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <item>
      <title>1Password for Linux 8.12.30</title>
      <pubDate>Mon, 10 Aug 2026 00:00:00 +0000</pubDate>
    </item>
    <item>
      <title>1Password for Linux 8.12.32</title>
      <pubDate>Tue, 11 Aug 2026 00:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>`;

function onePasswordSpec(): ToolSpec {
  return {
    kind: "vendorManifest",
    vendor: "onePassword",
    source: ONE_PASSWORD_SOURCE,
  };
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

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
        claudeManifest(fullClaudePlatforms()),
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
      ].sort(),
    );
    expect(locked.artifacts?.["linux-amd64-musl"]).toEqual({
      url: "https://downloads.example.invalid/claude-code-releases/2.1.220/linux-x64-musl/claude",
      sha256: SHA,
      size: 123,
    });
  });

  test("a known platform missing from the manifest is a hard error", async () => {
    const platforms = fullClaudePlatforms();
    delete platforms["darwin-arm64"];
    stubRoutes({
      "https://downloads.example.invalid/claude-code-releases/latest": text("2.1.220"),
      "https://downloads.example.invalid/claude-code-releases/2.1.220/manifest.json": json(
        claudeManifest(platforms),
      ),
    });

    const error = await resolveVendorManifest("claude", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/missing known platform id "darwin-arm64"/);
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
});

describe("resolveVendorManifest antigravity", () => {
  const spec: ToolSpec = {
    kind: "vendorManifest",
    vendor: "antigravity",
    source: "https://agy.example.invalid/manifests",
  };

  function agyRoutes(
    version: string | ((platform: string) => string),
  ): Record<string, () => Response> {
    const routes: Record<string, () => Response> = {};
    for (const { os, arch } of ALL_PLATFORMS) {
      const platform = `${os}_${arch}`;
      routes[`https://agy.example.invalid/manifests/${platform}.json`] = json({
        version: typeof version === "function" ? version(platform) : version,
        url: `https://agy.example.invalid/download/${platform}`,
        sha512: SHA512,
      });
    }
    return routes;
  }

  test("records the published sha512 with a null sha256 for every platform", async () => {
    stubRoutes(agyRoutes("1.1.7"));

    const locked = await resolveVendorManifest("agy", spec);

    expect(locked.version).toBe("1.1.7");
    expect(Object.keys(locked.artifacts ?? {})).toHaveLength(4);
    expect(locked.artifacts?.["darwin-arm64"]).toEqual({
      url: "https://agy.example.invalid/download/darwin_arm64",
      sha256: null,
      sha512: SHA512,
    });
  });

  test("disagreeing per-platform versions are a hard error", async () => {
    stubRoutes(agyRoutes((platform) => (platform === "darwin_arm64" ? "9.9.9" : "1.1.7")));

    const error = await resolveVendorManifest("agy", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/agy\.example\.invalid/);
  });

  test("a platform manifest missing fields is a hard error", async () => {
    const routes = agyRoutes("1.1.7");
    routes["https://agy.example.invalid/manifests/linux_amd64.json"] = json({ version: "1.1.7" });
    stubRoutes(routes);

    const error = await resolveVendorManifest("agy", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/linux_amd64 manifest missing fields/);
  });
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

describe("resolveVendorManifest onePassword", () => {
  test("selects the newest local feed item and records only its arm64 artifact", async () => {
    const requests = stubRoutes({ [ONE_PASSWORD_SOURCE]: text(ONE_PASSWORD_FEED) });

    const locked = await resolveVendorManifest("1password", onePasswordSpec());

    expect(locked.version).toBe("8.12.32");
    expect(locked.artifacts).toEqual({
      "linux-arm64": {
        url: "https://downloads.1password.com/linux/tar/stable/aarch64/1password-8.12.32.arm64.tar.gz",
        sha256: null,
      },
    });
    expect(locked.artifacts?.["linux-arm64"]).not.toHaveProperty("emulated");
    expect(Object.keys(locked.artifacts ?? {})).toEqual(["linux-arm64"]);
    expect(requests).toEqual([ONE_PASSWORD_SOURCE]);
  });

  test("rejects a malformed title with the source named", async () => {
    stubRoutes({
      [ONE_PASSWORD_SOURCE]: text(
        ONE_PASSWORD_FEED.replace("1Password for Linux 8.12.32", "1Password Linux 8.12.32"),
      ),
    });

    const error = await resolveVendorManifest("1password", onePasswordSpec()).catch(
      (e: unknown) => e,
    );

    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(ONE_PASSWORD_SOURCE);
  });

  test("raises ResolutionError when the feed fetch fails", async () => {
    stubRoutes({ [ONE_PASSWORD_SOURCE]: () => new Response("unavailable", { status: 503 }) });

    const error = await resolveVendorManifest("1password", onePasswordSpec()).catch(
      (e: unknown) => e,
    );

    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(ONE_PASSWORD_SOURCE);
  });
});

const FLUTTER_SOURCE = "https://storage.example.invalid/flutter/releases";
const FLUTTER_LINUX_MANIFEST = JSON.stringify({
  base_url: "https://storage.example.invalid/flutter/releases",
  current_release: {
    stable: "hash_linux_stable",
  },
  releases: [
    {
      hash: "hash_linux_stable",
      channel: "stable",
      version: "3.29.0",
      archive: "stable/linux/flutter_linux_3.29.0-stable.tar.xz",
      sha256: "linux_sha256_hex",
    },
  ],
});
const FLUTTER_MACOS_MANIFEST = JSON.stringify({
  base_url: "https://storage.example.invalid/flutter/releases",
  current_release: {
    stable: "hash_macos_stable",
  },
  releases: [
    {
      hash: "hash_macos_stable",
      channel: "stable",
      version: "3.29.0",
      dart_sdk_arch: "x64",
      archive: "stable/macos/flutter_macos_3.29.0-stable.zip",
      sha256: "macos_x64_sha256_hex",
    },
    {
      hash: "hash_macos_stable",
      channel: "stable",
      version: "3.29.0",
      dart_sdk_arch: "arm64",
      archive: "stable/macos/flutter_macos_arm64_3.29.0-stable.zip",
      sha256: "macos_arm64_sha256_hex",
    },
  ],
});

function flutterSpec(): ToolSpec {
  return {
    kind: "vendorManifest",
    vendor: "flutter",
    source: FLUTTER_SOURCE,
    emulatedPlatforms: ["linux-arm64"],
  };
}

describe("resolveVendorManifest flutter", () => {
  test("resolves stable releases for linux and macos across architectures", async () => {
    const requests = stubRoutes({
      [`${FLUTTER_SOURCE}/releases_linux.json`]: text(FLUTTER_LINUX_MANIFEST),
      [`${FLUTTER_SOURCE}/releases_macos.json`]: text(FLUTTER_MACOS_MANIFEST),
    });

    const locked = await resolveVendorManifest("flutter", flutterSpec());

    expect(locked.version).toBe("3.29.0");
    expect(locked.artifacts).toEqual({
      "linux-amd64": {
        url: "https://storage.example.invalid/flutter/releases/stable/linux/flutter_linux_3.29.0-stable.tar.xz",
        sha256: "linux_sha256_hex",
      },
      "linux-arm64": {
        url: "https://storage.example.invalid/flutter/releases/stable/linux/flutter_linux_3.29.0-stable.tar.xz",
        sha256: "linux_sha256_hex",
        emulated: true,
      },
      "darwin-amd64": {
        url: "https://storage.example.invalid/flutter/releases/stable/macos/flutter_macos_3.29.0-stable.zip",
        sha256: "macos_x64_sha256_hex",
      },
      "darwin-arm64": {
        url: "https://storage.example.invalid/flutter/releases/stable/macos/flutter_macos_arm64_3.29.0-stable.zip",
        sha256: "macos_arm64_sha256_hex",
      },
    });
    expect(requests).toEqual([
      `${FLUTTER_SOURCE}/releases_linux.json`,
      `${FLUTTER_SOURCE}/releases_macos.json`,
    ]);
  });

  test("raises ResolutionError when manifest request fails", async () => {
    stubRoutes({
      [`${FLUTTER_SOURCE}/releases_linux.json`]: () => new Response("failed", { status: 500 }),
      [`${FLUTTER_SOURCE}/releases_macos.json`]: text(FLUTTER_MACOS_MANIFEST),
    });

    const error = await resolveVendorManifest("flutter", flutterSpec()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(FLUTTER_SOURCE);
  });
});

const ANDROID_SOURCE = "https://dl.google.com/android/cli/latest";
const ANDROID_VERSION = "1.0.15985488";
const ANDROID_VERSION_BASE = `https://dl.google.com/android/cli/${ANDROID_VERSION}`;
const DUMMY_LATEST_LINUX_BINARY = `android launcher binary version=${ANDROID_VERSION} data`;
const DUMMY_LINUX_BINARY = `pinned linux android binary version=${ANDROID_VERSION} data`;
const DUMMY_DARWIN_ARM64_BINARY = "darwin arm64 android binary payload";
const DUMMY_DARWIN_X64_BINARY = "darwin x64 android binary payload";

function androidSpec(source = ANDROID_SOURCE): ToolSpec {
  return {
    kind: "vendorManifest",
    vendor: "android",
    source,
    emulatedPlatforms: ["linux-arm64"],
  };
}

/**
 * The `latest` body differs from every version-pinned body on purpose: it is the
 * only way to prove each recorded digest was computed from the URL the lock
 * records, rather than from the moving URL used to discover the version.
 */
function androidRoutes(
  overrides: Record<string, () => Response> = {},
): Record<string, () => Response> {
  return {
    [`${ANDROID_SOURCE}/linux_x86_64/android`]: text(DUMMY_LATEST_LINUX_BINARY),
    [`${ANDROID_VERSION_BASE}/linux_x86_64/android`]: text(DUMMY_LINUX_BINARY),
    [`${ANDROID_VERSION_BASE}/darwin_arm64/android`]: text(DUMMY_DARWIN_ARM64_BINARY),
    [`${ANDROID_VERSION_BASE}/darwin_x86_64/android`]: text(DUMMY_DARWIN_X64_BINARY),
    ...overrides,
  };
}

describe("resolveVendorManifest android", () => {
  test("records version-pinned urls with digests from the version-pinned bodies", async () => {
    stubRoutes(androidRoutes());

    const locked = await resolveVendorManifest("android", androidSpec());

    expect(locked.version).toBe(ANDROID_VERSION);
    expect(locked.source).toBe(ANDROID_SOURCE);
    expect(locked.artifacts).toEqual({
      "linux-amd64": {
        url: `${ANDROID_VERSION_BASE}/linux_x86_64/android`,
        sha256: createHash("sha256").update(Buffer.from(DUMMY_LINUX_BINARY)).digest("hex"),
        size: Buffer.byteLength(DUMMY_LINUX_BINARY),
      },
      "linux-arm64": {
        url: `${ANDROID_VERSION_BASE}/linux_x86_64/android`,
        sha256: createHash("sha256").update(Buffer.from(DUMMY_LINUX_BINARY)).digest("hex"),
        size: Buffer.byteLength(DUMMY_LINUX_BINARY),
        emulated: true,
      },
      "darwin-amd64": {
        url: `${ANDROID_VERSION_BASE}/darwin_x86_64/android`,
        sha256: createHash("sha256").update(Buffer.from(DUMMY_DARWIN_X64_BINARY)).digest("hex"),
        size: Buffer.byteLength(DUMMY_DARWIN_X64_BINARY),
      },
      "darwin-arm64": {
        url: `${ANDROID_VERSION_BASE}/darwin_arm64/android`,
        sha256: createHash("sha256").update(Buffer.from(DUMMY_DARWIN_ARM64_BINARY)).digest("hex"),
        size: Buffer.byteLength(DUMMY_DARWIN_ARM64_BINARY),
      },
    });
  });

  test("reads latest only to discover the version", async () => {
    const requests = stubRoutes(androidRoutes());

    await resolveVendorManifest("android", androidSpec());

    expect(requests).toEqual([
      `${ANDROID_SOURCE}/linux_x86_64/android`,
      `${ANDROID_VERSION_BASE}/linux_x86_64/android`,
      `${ANDROID_VERSION_BASE}/darwin_arm64/android`,
      `${ANDROID_VERSION_BASE}/darwin_x86_64/android`,
    ]);
  });

  test("raises ResolutionError when binary cannot be fetched", async () => {
    stubRoutes(
      androidRoutes({
        [`${ANDROID_SOURCE}/linux_x86_64/android`]: () => new Response("404", { status: 404 }),
      }),
    );

    const error = await resolveVendorManifest("android", androidSpec()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(`${ANDROID_SOURCE}/linux_x86_64/android`);
  });

  test("raises ResolutionError when the version-pinned body reports another version", async () => {
    stubRoutes(
      androidRoutes({
        [`${ANDROID_VERSION_BASE}/linux_x86_64/android`]: text(
          "pinned linux android binary version=1.0.99999999 data",
        ),
      }),
    );

    const error = await resolveVendorManifest("android", androidSpec()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain('reports version "1.0.99999999"');
  });

  test("accepts a source with a trailing slash", async () => {
    stubRoutes(androidRoutes());

    const locked = await resolveVendorManifest("android", androidSpec(`${ANDROID_SOURCE}/`));

    expect(locked.artifacts?.["linux-amd64"]?.url).toBe(
      `${ANDROID_VERSION_BASE}/linux_x86_64/android`,
    );
  });

  test("raises ResolutionError when a version-pinned binary cannot be fetched", async () => {
    stubRoutes(
      androidRoutes({
        [`${ANDROID_VERSION_BASE}/darwin_arm64/android`]: () =>
          new Response("404", { status: 404 }),
      }),
    );

    const error = await resolveVendorManifest("android", androidSpec()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(`${ANDROID_VERSION_BASE}/darwin_arm64/android`);
  });

  test("raises ResolutionError when version cannot be extracted from binary", async () => {
    stubRoutes(
      androidRoutes({
        [`${ANDROID_SOURCE}/linux_x86_64/android`]: text("corrupted binary without version string"),
      }),
    );

    const error = await resolveVendorManifest("android", androidSpec()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain("could not extract version");
  });

  test("raises ResolutionError when the extracted version is not a version segment", async () => {
    stubRoutes(
      androidRoutes({
        [`${ANDROID_SOURCE}/linux_x86_64/android`]: text("android launcher binary version=.. data"),
      }),
    );

    const error = await resolveVendorManifest("android", androidSpec()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain("invalid version");
  });

  test("raises ResolutionError when the source does not end in /latest", async () => {
    stubRoutes(androidRoutes());

    const error = await resolveVendorManifest(
      "android",
      androidSpec("https://dl.google.com/android/cli"),
    ).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain("/latest");
  });
});
