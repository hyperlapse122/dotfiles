import { describe, expect, test } from "vite-plus/test";
import {
  ALL_PLATFORMS,
  ALL_PLATFORMS_WITH_MUSL,
  platformKey,
  type Platform,
} from "../src/platforms.js";
import { REGISTRY } from "../src/registry.js";

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
  omp: {
    // A lone per-platform binary (oh-my-pi ships a bare executable, not pi's
    // dir bundle); linux publishes glibc AND static musl.
    "linux-amd64": "omp-linux-x64",
    "linux-arm64": "omp-linux-arm64",
    "darwin-amd64": "omp-darwin-x64",
    "darwin-arm64": "omp-darwin-arm64",
    // linuxMusl: distinct static-musl builds next to the glibc ones.
    "linux-amd64-musl": "omp-linux-musl-x64",
    "linux-arm64-musl": "omp-linux-musl-arm64",
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
