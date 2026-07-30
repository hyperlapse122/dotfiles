import {
  archiveExtension,
  executableExtension,
  muslTarget,
  rustArch,
  rustTarget,
  versionFromTag,
  type Architecture,
  type OperatingSystem,
} from "./platforms.js";
import type { Registry } from "./types.js";

/**
 * Tool registry — the single place a tool is declared.
 *
 * Each `asset` selector reproduces the filename the corresponding chezmoi
 * template builds today, so a migrated external resolves the same URL it
 * resolved before. The selectors stay functions rather than pattern strings
 * because upstream naming genuinely varies per OS (marksman ships three
 * unrelated shapes) and some names embed the tag itself (shellcheck).
 */

/** buf names arm64 `aarch64` on linux but `arm64` on darwin and windows. */
function bufArch(os: OperatingSystem, arch: Architecture): string {
  if (arch === "amd64") return "x86_64";
  return os === "linux" ? "aarch64" : "arm64";
}

function capitalized(os: OperatingSystem): string {
  return os.charAt(0).toUpperCase() + os.slice(1);
}

/** The `x64`/`arm64` arch spelling most npm-adjacent releases publish. */
function x64Arch(arch: Architecture): string {
  return arch === "amd64" ? "x64" : arch;
}

/** The `win32` os spelling most npm-adjacent releases publish. */
function win32Os(os: OperatingSystem): string {
  return os === "windows" ? "win32" : os;
}

export const REGISTRY: Registry = {
  "ast-grep": {
    kind: "githubRelease",
    source: "ast-grep/ast-grep",
    asset: ({ os, arch }) => `app-${rustArch(arch)}-${rustTarget(os)}.zip`,
  },

  buf: {
    kind: "githubRelease",
    source: "bufbuild/buf",
    asset: ({ os, arch }) => `buf-${capitalized(os)}-${bufArch(os, arch)}${archiveExtension(os)}`,
  },

  marksman: {
    kind: "githubRelease",
    source: "artempyanykh/marksman",
    asset: ({ os, arch }) => {
      switch (os) {
        case "linux":
          return `marksman-linux-${x64Arch(arch)}`;
        case "darwin":
          return "marksman-macos";
        case "windows":
          return "marksman.exe";
      }
    },
  },

  // Installed on darwin only; every other platform gets jq from a package manager.
  jq: {
    kind: "githubRelease",
    source: "jqlang/jq",
    asset: ({ os, arch }) => (os === "darwin" ? `jq-macos-${arch}` : null),
  },

  shellcheck: {
    kind: "githubRelease",
    source: "koalaman/shellcheck",
    // The windows asset is arch-less; unix assets carry os and rust arch.
    asset: ({ os, arch }, tag) =>
      os === "windows"
        ? `shellcheck-${tag}.zip`
        : `shellcheck-${tag}.${os}.${rustArch(arch)}.tar.gz`,
  },

  "wasm-pack": {
    kind: "githubRelease",
    source: "wasm-bindgen/wasm-pack",
    // Ships .tar.gz on every platform, and only a static musl build for linux.
    asset: ({ os, arch }, tag) => `wasm-pack-${tag}-${rustArch(arch)}-${muslTarget(os)}.tar.gz`,
    emulatedPlatforms: ["windows-arm64"],
  },

  "rust-analyzer": {
    kind: "githubRelease",
    source: "rust-lang/rust-analyzer",
    // Unix publishes a gzipped raw binary; only windows ships a real archive.
    asset: ({ os, arch }) =>
      `rust-analyzer-${rustArch(arch)}-${rustTarget(os)}${os === "windows" ? ".zip" : ".gz"}`,
  },

  uv: {
    kind: "githubRelease",
    source: "astral-sh/uv",
    asset: ({ os, arch }) => `uv-${rustArch(arch)}-${muslTarget(os)}${archiveExtension(os)}`,
  },

  gh: {
    kind: "githubRelease",
    source: "cli/cli",
    // darwin ships .zip where the shared convention would give .tar.gz.
    asset: ({ os, arch }, tag) => {
      const osName = os === "darwin" ? "macOS" : os;
      const extension = os === "linux" ? ".tar.gz" : ".zip";
      return `gh_${versionFromTag(tag)}_${osName}_${arch}${extension}`;
    },
  },

  garden: {
    kind: "githubRelease",
    source: "garden-rs/garden",
    asset: ({ os, arch }, tag) =>
      `garden-${versionFromTag(tag)}-${rustArch(arch)}-${rustTarget(os)}${archiveExtension(os)}`,
    emulatedPlatforms: ["windows-arm64"],
  },

  "docker-credential-helpers": {
    kind: "githubRelease",
    source: "docker/docker-credential-helpers",
    asset: ({ os, arch }, tag) => {
      const store = os === "linux" ? "secretservice" : os === "darwin" ? "osxkeychain" : "wincred";
      return `docker-credential-${store}-${tag}.${os}-${arch}${executableExtension(os)}`;
    },
  },

  "wakatime-cli": {
    kind: "githubRelease",
    source: "wakatime/wakatime-cli",
    asset: ({ os, arch }) => `wakatime-cli-${os}-${arch}.zip`,
  },

  minikube: {
    kind: "githubRelease",
    source: "kubernetes/minikube",
    asset: ({ os, arch }) => `minikube-${os}-${arch}.tar.gz`,
    emulatedPlatforms: ["windows-arm64"],
  },

  // Tag from the GitHub release, binary from dl.k8s.io — version only, and the
  // external keeps building the download URL from it.
  kubectl: { kind: "githubRelease", source: "kubernetes/kubernetes" },

  // As kubectl: tag from GitHub, archive from get.helm.sh.
  helm: { kind: "githubRelease", source: "helm/helm" },

  /* ---------- ai-agents.toml tools ---------- */

  codex: {
    kind: "githubRelease",
    source: "openai/codex",
    // Tags carry a `rust-v` prefix; the linux build is static musl.
    asset: ({ os, arch }) => `codex-package-${rustArch(arch)}-${muslTarget(os)}.tar.zst`,
  },

  "agent-browser": {
    kind: "githubRelease",
    source: "vercel-labs/agent-browser",
    // Bare per-platform binaries; linux ships glibc AND static musl (KTD11),
    // windows carries .exe. No win32-arm64 build upstream — windows-arm64
    // borrows the x64 binary under emulation, like garden/minikube/wasm-pack.
    linuxMusl: true,
    asset: ({ os, arch, libc }) =>
      `agent-browser-${win32Os(os)}${libc === "musl" ? "-musl" : ""}-${x64Arch(arch)}${executableExtension(os)}`,
    emulatedPlatforms: ["windows-arm64"],
  },

  omp: {
    kind: "githubRelease",
    source: "can1357/oh-my-pi",
    // A lone per-platform binary (oh-my-pi is a fork of pi but ships a bare
    // executable, not pi's whole-dir bundle): linux publishes glibc AND static
    // musl, darwin and windows carry the raw binary (windows with .exe). Asset
    // names use the raw os (`omp-windows-x64.exe`), not the win32 spelling. No
    // windows-arm64 build upstream, so that target is deliberately not locked.
    linuxMusl: true,
    asset: ({ os, arch, libc }) =>
      os === "windows" && arch === "arm64"
        ? null
        : `omp-${os}${libc === "musl" ? "-musl" : ""}-${x64Arch(arch)}${executableExtension(os)}`,
  },

  codegraph: {
    kind: "githubRelease",
    source: "colbymchenry/codegraph",
    // win32 assets are .zip, not the .tar.gz today's template names on windows
    // (that render is broken upstream); the lock records what the release
    // actually publishes.
    asset: ({ os, arch }) => `codegraph-${win32Os(os)}-${x64Arch(arch)}${archiveExtension(os)}`,
  },

  kitty: {
    kind: "githubRelease",
    source: "kovidgoyal/kitty",
    // Linux-only app bundle: upstream publishes kitty-<version>-x86_64.txz and
    // kitty-<version>-arm64.txz, embedding the bare version (no leading `v`).
    // macOS ships only a .dmg (chezmoi cannot extract one) and there is no
    // windows build, so both are deliberately not locked. The linux arm64
    // spelling is `arm64` here, NOT bufArch's `aarch64`.
    asset: ({ os, arch }, tag) =>
      os === "linux"
        ? `kitty-${versionFromTag(tag)}-${arch === "amd64" ? "x86_64" : "arm64"}.txz`
        : null,
  },

  aoe: {
    kind: "githubRelease",
    source: "agent-of-empires/agent-of-empires",
    // No windows build upstream; the external is gated the same way.
    asset: ({ os, arch }) => (os === "windows" ? null : `aoe-${os}-${arch}.tar.gz`),
  },

  // macOS runs the CLIProxyAPI binary directly under launchd (linux uses the
  // ociImage quadlet); darwin assets spell arm64 as aarch64.
  "cli-proxy-api-binary": {
    kind: "githubRelease",
    source: "router-for-me/CLIProxyAPI",
    asset: ({ os, arch }, tag) =>
      os === "darwin"
        ? `CLIProxyAPI_${versionFromTag(tag)}_darwin_${arch === "arm64" ? "aarch64" : "amd64"}.tar.gz`
        : null,
  },

  /* ---------- version-only githubRelease entries ---------- */

  // The newest tag of the repo's own release train doubles as the ref for the
  // playwright-cli skill external (agents.skills.external entry with no ref).
  "playwright-cli": { kind: "githubRelease", source: "microsoft/playwright-cli" },

  "compound-engineering": {
    kind: "githubRelease",
    source: "everyinc/compound-engineering-plugin",
    // The repo interleaves marketplace-* and cli-* tag trains, so
    // `releases/latest` would eventually resolve to the wrong one (KTD10).
    tagPrefix: "compound-engineering-",
  },

  // Version-only tag for the build-open-design script's onchange trigger.
  "open-design": { kind: "githubRelease", source: "nexu-io/open-design" },

  /* ---------- gitlabRelease ---------- */

  // One key serves the vcs.toml binary and both bundled skills (AE5).
  glab: { kind: "gitlabRelease", source: "https://gitlab.com/api/v4/projects/34675721" },

  /* ---------- vendorManifest ---------- */

  claude: {
    kind: "vendorManifest",
    vendor: "claude",
    source: "https://downloads.claude.ai/claude-code-releases",
  },

  winbox: {
    kind: "vendorManifest",
    vendor: "winbox",
    source: "https://download.mikrotik.com/routeros/winbox/LATEST.4",
  },

  /* ---------- gitRef ---------- */

  // The improve skill has no releases/tags; agents.skills.external pins its
  // `ref: main` branch head to a commit.
  improve: { kind: "gitRef", source: "shadcn/improve", ref: "refs/heads/main" },

  /* ---------- ociImage: the cli-proxy-api quadlet images ---------- */

  // eceasy/cli-proxy-api is a third-party Docker Hub republisher of
  // router-for-me/CLIProxyAPI, not an upstream-owned namespace. The digest
  // pin mitigates tag mutation, not provenance — this trust boundary is
  // deliberate (Risks & Dependencies in the quadlet plan).
  "cli-proxy-api": {
    kind: "ociImage",
    source: "docker.io/eceasy/cli-proxy-api",
    tag: "latest",
  },

  // CPA-Manager-Plus admin panel, published by its author on GHCR.
  "cpa-manager-plus": {
    kind: "ociImage",
    source: "ghcr.io/seakee/cpa-manager-plus",
    tag: "latest",
  },
};
