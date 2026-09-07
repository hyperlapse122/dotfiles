import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveGitHubRelease } from "../src/github.js";
import {
  ALL_PLATFORMS,
  ALL_PLATFORMS_WITH_MUSL,
  platformKey,
  type Platform,
} from "../src/platforms.js";
import { REGISTRY } from "../src/registry.js";
import type { ToolSpec } from "../src/types.js";

/**
 * Sentinel tag for the tag-embedding selectors (shellcheck, wasm-pack, gh,
 * garden, docker-credential-helpers). Parity lives in the name shape, not the
 * version, so a fixed tag keeps the test green across hourly lock refreshes.
 */
const TAG = "v0.0.0";

/**
 * The V4 baseline: exact upstream asset names per tool and platform, captured
 * from the committed `.chezmoidata/releases.json` lock (whose entries each
 * matched a real published asset at resolution time) with the sentinel tag
 * substituted. Explicit `null` rows record deliberately untargeted platforms —
 * a missing row and a wrongly-null selector would be indistinguishable.
 */
const EXPECTED: Record<string, Record<string, string | null>> = {
  "ast-grep": {
    "linux-amd64": "app-x86_64-unknown-linux-gnu.zip",
    "linux-arm64": "app-aarch64-unknown-linux-gnu.zip",
    "darwin-amd64": "app-x86_64-apple-darwin.zip",
    "darwin-arm64": "app-aarch64-apple-darwin.zip",
  },
  buf: {
    "linux-amd64": "buf-Linux-x86_64.tar.gz",
    // buf names linux arm64 `aarch64` but darwin arm64 `arm64`.
    "linux-arm64": "buf-Linux-aarch64.tar.gz",
    "darwin-amd64": "buf-Darwin-x86_64.tar.gz",
    "darwin-arm64": "buf-Darwin-arm64.tar.gz",
  },
  bun: {
    // bun spells amd64 `x64` but arm64 `aarch64`, on both linux and darwin.
    "linux-amd64": "bun-linux-x64.zip",
    "linux-arm64": "bun-linux-aarch64.zip",
    "linux-amd64-musl": "bun-linux-x64-musl.zip",
    "linux-arm64-musl": "bun-linux-aarch64-musl.zip",
    "darwin-amd64": "bun-darwin-x64.zip",
    "darwin-arm64": "bun-darwin-aarch64.zip",
  },
  chezmoi: {
    "linux-amd64": "chezmoi_0.0.0_linux_amd64.tar.gz",
    "linux-arm64": "chezmoi_0.0.0_linux_arm64.tar.gz",
    "darwin-amd64": "chezmoi_0.0.0_darwin_amd64.tar.gz",
    "darwin-arm64": "chezmoi_0.0.0_darwin_arm64.tar.gz",
  },
  marksman: {
    "linux-amd64": "marksman-linux-x64",
    "linux-arm64": "marksman-linux-arm64",
    "darwin-amd64": "marksman-macos",
    "darwin-arm64": "marksman-macos",
  },
  shellcheck: {
    "linux-amd64": "shellcheck-v0.0.0.linux.x86_64.tar.gz",
    "linux-arm64": "shellcheck-v0.0.0.linux.aarch64.tar.gz",
    "darwin-amd64": "shellcheck-v0.0.0.darwin.x86_64.tar.gz",
    "darwin-arm64": "shellcheck-v0.0.0.darwin.aarch64.tar.gz",
  },
  "wasm-pack": {
    // Ships .tar.gz on every platform, and only a static musl build for linux.
    "linux-amd64": "wasm-pack-v0.0.0-x86_64-unknown-linux-musl.tar.gz",
    "linux-arm64": "wasm-pack-v0.0.0-aarch64-unknown-linux-musl.tar.gz",
    "darwin-amd64": "wasm-pack-v0.0.0-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "wasm-pack-v0.0.0-aarch64-apple-darwin.tar.gz",
  },
  "rust-analyzer": {
    "linux-amd64": "rust-analyzer-x86_64-unknown-linux-gnu.gz",
    "linux-arm64": "rust-analyzer-aarch64-unknown-linux-gnu.gz",
    "darwin-amd64": "rust-analyzer-x86_64-apple-darwin.gz",
    "darwin-arm64": "rust-analyzer-aarch64-apple-darwin.gz",
  },
  uv: {
    "linux-amd64": "uv-x86_64-unknown-linux-musl.tar.gz",
    "linux-arm64": "uv-aarch64-unknown-linux-musl.tar.gz",
    "darwin-amd64": "uv-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "uv-aarch64-apple-darwin.tar.gz",
  },
  mise: {
    "linux-amd64": "mise-v0.0.0-linux-x64",
    "linux-arm64": "mise-v0.0.0-linux-arm64",
    "linux-amd64-musl": "mise-v0.0.0-linux-x64-musl",
    "linux-arm64-musl": "mise-v0.0.0-linux-arm64-musl",
    "darwin-amd64": "mise-v0.0.0-macos-x64",
    "darwin-arm64": "mise-v0.0.0-macos-arm64",
  },
  gh: {
    // darwin ships .zip spelled `macOS`; the leading `v` is stripped.
    "linux-amd64": "gh_0.0.0_linux_amd64.tar.gz",
    "linux-arm64": "gh_0.0.0_linux_arm64.tar.gz",
    "darwin-amd64": "gh_0.0.0_macOS_amd64.zip",
    "darwin-arm64": "gh_0.0.0_macOS_arm64.zip",
  },
  garden: {
    "linux-amd64": "garden-0.0.0-x86_64-unknown-linux-gnu.tar.gz",
    "linux-arm64": "garden-0.0.0-aarch64-unknown-linux-gnu.tar.gz",
    "darwin-amd64": "garden-0.0.0-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "garden-0.0.0-aarch64-apple-darwin.tar.gz",
  },
  "docker-credential-helpers": {
    "linux-amd64": "docker-credential-secretservice-v0.0.0.linux-amd64",
    "linux-arm64": "docker-credential-secretservice-v0.0.0.linux-arm64",
    "darwin-amd64": "docker-credential-osxkeychain-v0.0.0.darwin-amd64",
    "darwin-arm64": "docker-credential-osxkeychain-v0.0.0.darwin-arm64",
  },
  "wakatime-cli": {
    "linux-amd64": "wakatime-cli-linux-amd64.zip",
    "linux-arm64": "wakatime-cli-linux-arm64.zip",
    "darwin-amd64": "wakatime-cli-darwin-amd64.zip",
    "darwin-arm64": "wakatime-cli-darwin-arm64.zip",
  },
  minikube: {
    "linux-amd64": "minikube-linux-amd64.tar.gz",
    "linux-arm64": "minikube-linux-arm64.tar.gz",
    "darwin-amd64": "minikube-darwin-amd64.tar.gz",
    "darwin-arm64": "minikube-darwin-arm64.tar.gz",
  },
  "agent-browser": {
    "linux-amd64": "agent-browser-linux-x64",
    "linux-arm64": "agent-browser-linux-arm64",
    "darwin-amd64": "agent-browser-darwin-x64",
    "darwin-arm64": "agent-browser-darwin-arm64",
    // linuxMusl: distinct static-musl builds next to the glibc ones.
    "linux-amd64-musl": "agent-browser-linux-musl-x64",
    "linux-arm64-musl": "agent-browser-linux-musl-arm64",
  },
  codegraph: {
    "linux-amd64": "codegraph-linux-x64.tar.gz",
    "linux-arm64": "codegraph-linux-arm64.tar.gz",
    "darwin-amd64": "codegraph-darwin-x64.tar.gz",
    "darwin-arm64": "codegraph-darwin-arm64.tar.gz",
  },
  aoe: {
    "linux-amd64": "aoe-linux-amd64.tar.gz",
    "linux-arm64": "aoe-linux-arm64.tar.gz",
    "darwin-amd64": "aoe-darwin-amd64.tar.gz",
    "darwin-arm64": "aoe-darwin-arm64.tar.gz",
  },
  codex: {
    "linux-amd64": "codex-x86_64-unknown-linux-musl.tar.gz",
    "linux-arm64": "codex-aarch64-unknown-linux-musl.tar.gz",
    "darwin-amd64": "codex-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "codex-aarch64-apple-darwin.tar.gz",
  },
};

describe("registry asset selectors", () => {
  // Iterate the EXPECTED table's own keys, never the spec's linuxMusl flag:
  // the table is the parity contract, so a spec that drops (or a table that
  // gains) musl coverage without the other must fail here, not pass silently.
  const platformByKey: Readonly<Record<string, Platform>> = Object.fromEntries(
    ALL_PLATFORMS_WITH_MUSL.map((platform) => [platformKey(platform), platform]),
  );
  for (const [tool, expectedByPlatform] of Object.entries(EXPECTED)) {
    const spec = REGISTRY[tool];
    describe(tool, () => {
      // The table must cover exactly the platforms the spec targets. Drift in
      // either direction — a removed linuxMusl flag with musl rows left behind,
      // or musl rows added without the flag — fails this assertion.
      const specPlatforms = spec?.linuxMusl ? ALL_PLATFORMS_WITH_MUSL : ALL_PLATFORMS;
      test("covers exactly the spec's target platforms", () => {
        expect(Object.keys(expectedByPlatform).sort()).toEqual(
          specPlatforms.map(platformKey).sort(),
        );
      });
      for (const [key, expected] of Object.entries(expectedByPlatform)) {
        test(key, () => {
          const platform = platformByKey[key];
          expect(platform, `EXPECTED row ${tool}/${key} names an unknown platform`).toBeDefined();
          expect(spec?.asset?.(platform as Platform, TAG)).toBe(expected);
        });
      }
    });
  }
});

describe("bun asset variants", () => {
  // oven-sh/bun publishes -baseline, -profile and -android assets next to the
  // default builds. Selecting one would silently ship the wrong binary, so the
  // selector must never emit those suffixes on any target platform.
  const forbidden = ["-baseline", "-profile", "-android"];
  for (const platform of ALL_PLATFORMS_WITH_MUSL) {
    test(platformKey(platform), () => {
      const name = REGISTRY.bun?.asset?.(platform, TAG);
      expect(name).toBeDefined();
      for (const variant of forbidden) {
        expect(name, `${variant} variant selected`).not.toContain(variant);
      }
    });
  }
});

describe("registry selector partition", () => {
  test("every tool in the expected table has an asset selector", () => {
    for (const tool of Object.keys(EXPECTED)) {
      expect(typeof REGISTRY[tool]?.asset, tool).toBe("function");
    }
  });

  test("every registry tool absent from the table carries no asset selector", () => {
    for (const [tool, spec] of Object.entries(REGISTRY)) {
      if (tool in EXPECTED) continue;
      expect(spec.asset, tool).toBeUndefined();
    }
  });
});

describe("rolling-release tag pinning", () => {
  // A githubRelease entry with no tagPrefix resolves through `releases/latest`,
  // which is correct only while upstream publishes no rolling non-prerelease
  // release. These two do, so the prefix is load-bearing, not decoration.
  test.each([
    ["bun", "bun-v"],
    ["shellcheck", "v"],
  ])("%s pins its release train with tagPrefix %s", (tool, prefix) => {
    const spec = REGISTRY[tool as keyof typeof REGISTRY] as ToolSpec;
    expect(spec.kind).toBe("githubRelease");
    expect((spec as { tagPrefix?: string }).tagPrefix).toBe(prefix);
  });

  test("shellcheck's prefix excludes its rolling latest and stable tags", () => {
    const prefix = (REGISTRY.shellcheck as { tagPrefix?: string }).tagPrefix ?? "";
    expect(prefix).not.toBe("");
    expect("v0.11.0".startsWith(prefix)).toBe(true);
    expect("latest".startsWith(prefix)).toBe(false);
    expect("stable".startsWith(prefix)).toBe(false);
  });
});

describe("bun tag pinning", () => {
  const realFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  interface StubListedRelease {
    tag_name: string;
    prerelease?: boolean;
    draft?: boolean;
  }

  /** Every asset the bun selector names for `tag`, as the release would publish them. */
  function bunAssets(tag: string): { name: string; browser_download_url: string }[] {
    return ALL_PLATFORMS_WITH_MUSL.map((platform) => REGISTRY.bun?.asset?.(platform, tag))
      .filter((name): name is string => typeof name === "string")
      .map((name) => ({
        name,
        browser_download_url: `https://example.invalid/download/${tag}/${name}`,
      }));
  }

  function stubReleaseList(releases: StubListedRelease[]): void {
    const body = releases.map((entry) => ({ ...entry, assets: bunAssets(entry.tag_name) }));
    globalThis.fetch = (async () =>
      new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" },
      })) as typeof globalThis.fetch;
  }

  test("the registry entry declares a tag prefix", () => {
    // Without it, resolution falls back to releases/latest, which follows
    // oven-sh/bun's rolling `canary` tag the moment upstream stops flagging it
    // a prerelease.
    expect(REGISTRY.bun?.tagPrefix).toBe("bun-v");
  });

  test("the prefix matches the tag the committed lock already records", () => {
    expect("bun-v1.4.1".startsWith(REGISTRY.bun?.tagPrefix ?? "")).toBe(true);
  });

  test("resolution skips the canary train and selects the newest bun-v tag", async () => {
    stubReleaseList([
      { tag_name: "canary" },
      { tag_name: "bun-v1.4.1" },
      { tag_name: "bun-v1.4.0" },
    ]);

    const locked = await resolveGitHubRelease("bun", REGISTRY.bun as ToolSpec, undefined);

    expect(locked.version).toBe("bun-v1.4.1");
  });

  test("a release list holding only canary fails rather than resolving it", async () => {
    stubReleaseList([{ tag_name: "canary" }]);

    await expect(resolveGitHubRelease("bun", REGISTRY.bun as ToolSpec, undefined)).rejects.toThrow(
      /no stable release tag carries the prefix "bun-v"/,
    );
  });
});
