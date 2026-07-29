import { describe, expect, test } from "vite-plus/test";
import { ALL_PLATFORMS, MUSL_PLATFORMS, platformKey, type Platform } from "../src/platforms.js";
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
 *
 * Emulated windows-arm64 targets (wasm-pack, garden, minikube, agent-browser)
 * borrow the amd64 artifact at resolution time, which is resolver behavior and
 * out of scope here; their amd64 rows pin the borrowed name.
 */
const EXPECTED: Record<string, Record<string, string | null>> = {
  "ast-grep": {
    "linux-amd64": "app-x86_64-unknown-linux-gnu.zip",
    "linux-arm64": "app-aarch64-unknown-linux-gnu.zip",
    "darwin-amd64": "app-x86_64-apple-darwin.zip",
    "darwin-arm64": "app-aarch64-apple-darwin.zip",
    "windows-amd64": "app-x86_64-pc-windows-msvc.zip",
    "windows-arm64": "app-aarch64-pc-windows-msvc.zip",
  },
  buf: {
    "linux-amd64": "buf-Linux-x86_64.tar.gz",
    // buf names linux arm64 `aarch64` but darwin/windows arm64 `arm64`.
    "linux-arm64": "buf-Linux-aarch64.tar.gz",
    "darwin-amd64": "buf-Darwin-x86_64.tar.gz",
    "darwin-arm64": "buf-Darwin-arm64.tar.gz",
    "windows-amd64": "buf-Windows-x86_64.zip",
    "windows-arm64": "buf-Windows-arm64.zip",
  },
  marksman: {
    "linux-amd64": "marksman-linux-x64",
    "linux-arm64": "marksman-linux-arm64",
    "darwin-amd64": "marksman-macos",
    "darwin-arm64": "marksman-macos",
    "windows-amd64": "marksman.exe",
    "windows-arm64": "marksman.exe",
  },
  jq: {
    // darwin-only here; every other platform gets jq from a package manager.
    "linux-amd64": null,
    "linux-arm64": null,
    "darwin-amd64": "jq-macos-amd64",
    "darwin-arm64": "jq-macos-arm64",
    "windows-amd64": null,
    "windows-arm64": null,
  },
  shellcheck: {
    "linux-amd64": "shellcheck-v0.0.0.linux.x86_64.tar.gz",
    "linux-arm64": "shellcheck-v0.0.0.linux.aarch64.tar.gz",
    "darwin-amd64": "shellcheck-v0.0.0.darwin.x86_64.tar.gz",
    "darwin-arm64": "shellcheck-v0.0.0.darwin.aarch64.tar.gz",
    // The windows asset is arch-less.
    "windows-amd64": "shellcheck-v0.0.0.zip",
    "windows-arm64": "shellcheck-v0.0.0.zip",
  },
  "wasm-pack": {
    // Ships .tar.gz on every platform, and only a static musl build for linux.
    "linux-amd64": "wasm-pack-v0.0.0-x86_64-unknown-linux-musl.tar.gz",
    "linux-arm64": "wasm-pack-v0.0.0-aarch64-unknown-linux-musl.tar.gz",
    "darwin-amd64": "wasm-pack-v0.0.0-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "wasm-pack-v0.0.0-aarch64-apple-darwin.tar.gz",
    "windows-amd64": "wasm-pack-v0.0.0-x86_64-pc-windows-msvc.tar.gz",
    "windows-arm64": "wasm-pack-v0.0.0-aarch64-pc-windows-msvc.tar.gz",
  },
  "rust-analyzer": {
    // Unix publishes a gzipped raw binary; only windows ships a real archive.
    "linux-amd64": "rust-analyzer-x86_64-unknown-linux-gnu.gz",
    "linux-arm64": "rust-analyzer-aarch64-unknown-linux-gnu.gz",
    "darwin-amd64": "rust-analyzer-x86_64-apple-darwin.gz",
    "darwin-arm64": "rust-analyzer-aarch64-apple-darwin.gz",
    "windows-amd64": "rust-analyzer-x86_64-pc-windows-msvc.zip",
    "windows-arm64": "rust-analyzer-aarch64-pc-windows-msvc.zip",
  },
  uv: {
    "linux-amd64": "uv-x86_64-unknown-linux-musl.tar.gz",
    "linux-arm64": "uv-aarch64-unknown-linux-musl.tar.gz",
    "darwin-amd64": "uv-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "uv-aarch64-apple-darwin.tar.gz",
    "windows-amd64": "uv-x86_64-pc-windows-msvc.zip",
    "windows-arm64": "uv-aarch64-pc-windows-msvc.zip",
  },
  gh: {
    // darwin ships .zip spelled `macOS`; the leading `v` is stripped.
    "linux-amd64": "gh_0.0.0_linux_amd64.tar.gz",
    "linux-arm64": "gh_0.0.0_linux_arm64.tar.gz",
    "darwin-amd64": "gh_0.0.0_macOS_amd64.zip",
    "darwin-arm64": "gh_0.0.0_macOS_arm64.zip",
    "windows-amd64": "gh_0.0.0_windows_amd64.zip",
    "windows-arm64": "gh_0.0.0_windows_arm64.zip",
  },
  garden: {
    "linux-amd64": "garden-0.0.0-x86_64-unknown-linux-gnu.tar.gz",
    "linux-arm64": "garden-0.0.0-aarch64-unknown-linux-gnu.tar.gz",
    "darwin-amd64": "garden-0.0.0-x86_64-apple-darwin.tar.gz",
    "darwin-arm64": "garden-0.0.0-aarch64-apple-darwin.tar.gz",
    "windows-amd64": "garden-0.0.0-x86_64-pc-windows-msvc.zip",
    "windows-arm64": "garden-0.0.0-aarch64-pc-windows-msvc.zip",
  },
  "docker-credential-helpers": {
    "linux-amd64": "docker-credential-secretservice-v0.0.0.linux-amd64",
    "linux-arm64": "docker-credential-secretservice-v0.0.0.linux-arm64",
    "darwin-amd64": "docker-credential-osxkeychain-v0.0.0.darwin-amd64",
    "darwin-arm64": "docker-credential-osxkeychain-v0.0.0.darwin-arm64",
    "windows-amd64": "docker-credential-wincred-v0.0.0.windows-amd64.exe",
    "windows-arm64": "docker-credential-wincred-v0.0.0.windows-arm64.exe",
  },
  "wakatime-cli": {
    "linux-amd64": "wakatime-cli-linux-amd64.zip",
    "linux-arm64": "wakatime-cli-linux-arm64.zip",
    "darwin-amd64": "wakatime-cli-darwin-amd64.zip",
    "darwin-arm64": "wakatime-cli-darwin-arm64.zip",
    "windows-amd64": "wakatime-cli-windows-amd64.zip",
    "windows-arm64": "wakatime-cli-windows-arm64.zip",
  },
  minikube: {
    "linux-amd64": "minikube-linux-amd64.tar.gz",
    "linux-arm64": "minikube-linux-arm64.tar.gz",
    "darwin-amd64": "minikube-darwin-amd64.tar.gz",
    "darwin-arm64": "minikube-darwin-arm64.tar.gz",
    // minikube ships .tar.gz even on windows.
    "windows-amd64": "minikube-windows-amd64.tar.gz",
    "windows-arm64": "minikube-windows-arm64.tar.gz",
  },
  codex: {
    "linux-amd64": "codex-package-x86_64-unknown-linux-musl.tar.zst",
    "linux-arm64": "codex-package-aarch64-unknown-linux-musl.tar.zst",
    "darwin-amd64": "codex-package-x86_64-apple-darwin.tar.zst",
    "darwin-arm64": "codex-package-aarch64-apple-darwin.tar.zst",
    "windows-amd64": "codex-package-x86_64-pc-windows-msvc.tar.zst",
    "windows-arm64": "codex-package-aarch64-pc-windows-msvc.tar.zst",
  },
  kimi: {
    "linux-amd64": "kimi-code-linux-x64.zip",
    "linux-arm64": "kimi-code-linux-arm64.zip",
    "darwin-amd64": "kimi-code-darwin-x64.zip",
    "darwin-arm64": "kimi-code-darwin-arm64.zip",
    "windows-amd64": "kimi-code-win32-x64.zip",
    "windows-arm64": "kimi-code-win32-arm64.zip",
  },
  "agent-browser": {
    "linux-amd64": "agent-browser-linux-x64",
    "linux-arm64": "agent-browser-linux-arm64",
    "darwin-amd64": "agent-browser-darwin-x64",
    "darwin-arm64": "agent-browser-darwin-arm64",
    "windows-amd64": "agent-browser-win32-x64.exe",
    "windows-arm64": "agent-browser-win32-arm64.exe",
    // linuxMusl: distinct static-musl builds next to the glibc ones.
    "linux-amd64-musl": "agent-browser-linux-musl-x64",
    "linux-arm64-musl": "agent-browser-linux-musl-arm64",
  },
  opencode: {
    "linux-amd64": "opencode-linux-x64.tar.gz",
    "linux-arm64": "opencode-linux-arm64.tar.gz",
    "darwin-amd64": "opencode-darwin-x64.zip",
    "darwin-arm64": "opencode-darwin-arm64.zip",
    "windows-amd64": "opencode-windows-x64.zip",
    "windows-arm64": "opencode-windows-arm64.zip",
  },
  pi: {
    "linux-amd64": "pi-linux-x64.tar.gz",
    "linux-arm64": "pi-linux-arm64.tar.gz",
    "darwin-amd64": "pi-darwin-x64.tar.gz",
    "darwin-arm64": "pi-darwin-arm64.tar.gz",
    // Every consumer is POSIX-only, so windows is deliberately not locked.
    "windows-amd64": null,
    "windows-arm64": null,
  },
  omp: {
    // A lone per-platform binary (oh-my-pi ships a bare executable, not pi's
    // dir bundle); linux publishes glibc AND static musl, windows carries .exe.
    "linux-amd64": "omp-linux-x64",
    "linux-arm64": "omp-linux-arm64",
    "darwin-amd64": "omp-darwin-x64",
    "darwin-arm64": "omp-darwin-arm64",
    "windows-amd64": "omp-windows-x64.exe",
    // No windows-arm64 build upstream, so it is deliberately not locked.
    "windows-arm64": null,
    // linuxMusl: distinct static-musl builds next to the glibc ones.
    "linux-amd64-musl": "omp-linux-musl-x64",
    "linux-arm64-musl": "omp-linux-musl-arm64",
  },
  codegraph: {
    "linux-amd64": "codegraph-linux-x64.tar.gz",
    "linux-arm64": "codegraph-linux-arm64.tar.gz",
    "darwin-amd64": "codegraph-darwin-x64.tar.gz",
    "darwin-arm64": "codegraph-darwin-arm64.tar.gz",
    // win32 assets are .zip, not the .tar.gz the old template named.
    "windows-amd64": "codegraph-win32-x64.zip",
    "windows-arm64": "codegraph-win32-arm64.zip",
  },
  aoe: {
    "linux-amd64": "aoe-linux-amd64.tar.gz",
    "linux-arm64": "aoe-linux-arm64.tar.gz",
    "darwin-amd64": "aoe-darwin-amd64.tar.gz",
    "darwin-arm64": "aoe-darwin-arm64.tar.gz",
    // No windows build upstream; the external is gated the same way.
    "windows-amd64": null,
    "windows-arm64": null,
  },
  "cli-proxy-api-binary": {
    // darwin-only: linux runs the ociImage quadlet, windows is out of scope.
    // darwin assets spell arm64 as aarch64; the leading `v` is stripped.
    "linux-amd64": null,
    "linux-arm64": null,
    "darwin-amd64": "CLIProxyAPI_0.0.0_darwin_amd64.tar.gz",
    "darwin-arm64": "CLIProxyAPI_0.0.0_darwin_aarch64.tar.gz",
    "windows-amd64": null,
    "windows-arm64": null,
  },
};

describe("registry asset selectors", () => {
  // Iterate the EXPECTED table's own keys, never the spec's linuxMusl flag:
  // the table is the parity contract, so a spec that drops (or a table that
  // gains) musl coverage without the other must fail here, not pass silently.
  const platformByKey = new Map<string, Platform>(
    [...ALL_PLATFORMS, ...MUSL_PLATFORMS].map((platform) => [platformKey(platform), platform]),
  );
  for (const [tool, expectedByPlatform] of Object.entries(EXPECTED)) {
    const spec = REGISTRY[tool];
    describe(tool, () => {
      // The table must cover exactly the platforms the spec targets. Drift in
      // either direction — a removed linuxMusl flag with musl rows left behind,
      // or musl rows added without the flag — fails this assertion.
      const specPlatforms = spec?.linuxMusl ? [...ALL_PLATFORMS, ...MUSL_PLATFORMS] : ALL_PLATFORMS;
      test("covers exactly the spec's target platforms", () => {
        expect(Object.keys(expectedByPlatform).sort()).toEqual(
          specPlatforms.map(platformKey).sort(),
        );
      });
      for (const [key, expected] of Object.entries(expectedByPlatform)) {
        test(key, () => {
          const platform = platformByKey.get(key);
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
