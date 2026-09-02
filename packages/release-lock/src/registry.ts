import {
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
 * Each `asset` selector matches the filename the corresponding chezmoi
 * template builds. The selectors stay functions rather than pattern strings
 * because upstream naming varies per OS (marksman ships two unrelated shapes)
 * and some names embed the tag itself (shellcheck).
 */
/** buf names arm64 `aarch64` on linux but `arm64` on darwin. */
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

export const REGISTRY: Registry = {
  "ast-grep": {
    kind: "githubRelease",
    source: "ast-grep/ast-grep",
    asset: ({ os, arch }) => `app-${rustArch(arch)}-${rustTarget(os)}.zip`,
  },

  buf: {
    kind: "githubRelease",
    source: "bufbuild/buf",
    asset: ({ os, arch }) => `buf-${capitalized(os)}-${bufArch(os, arch)}.tar.gz`,
  },

  chezmoi: {
    kind: "githubRelease",
    source: "twpayne/chezmoi",
    asset: ({ os, arch }, tag) => `chezmoi_${versionFromTag(tag)}_${os}_${arch}.tar.gz`,
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
      }
    },
  },

  shellcheck: {
    kind: "githubRelease",
    source: "koalaman/shellcheck",
    asset: ({ os, arch }, tag) => `shellcheck-${tag}.${os}.${rustArch(arch)}.tar.gz`,
  },

  "wasm-pack": {
    kind: "githubRelease",
    source: "wasm-bindgen/wasm-pack",
    // Ships .tar.gz on every platform, and only a static musl build for linux.
    asset: ({ os, arch }, tag) => `wasm-pack-${tag}-${rustArch(arch)}-${muslTarget(os)}.tar.gz`,
  },

  "rust-analyzer": {
    kind: "githubRelease",
    source: "rust-lang/rust-analyzer",
    asset: ({ os, arch }) => `rust-analyzer-${rustArch(arch)}-${rustTarget(os)}.gz`,
  },

  uv: {
    kind: "githubRelease",
    source: "astral-sh/uv",
    asset: ({ os, arch }) => `uv-${rustArch(arch)}-${muslTarget(os)}.tar.gz`,
  },
  mise: {
    kind: "githubRelease",
    source: "jdx/mise",
    linuxMusl: true,
    asset: ({ os, arch, libc }, tag) =>
      `mise-${tag}-${os === "darwin" ? "macos" : os}-${x64Arch(arch)}${libc === "musl" ? "-musl" : ""}`,
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
      `garden-${versionFromTag(tag)}-${rustArch(arch)}-${rustTarget(os)}.tar.gz`,
  },

  "docker-credential-helpers": {
    kind: "githubRelease",
    source: "docker/docker-credential-helpers",
    asset: ({ os, arch }, tag) => {
      const store = os === "linux" ? "secretservice" : "osxkeychain";
      return `docker-credential-${store}-${tag}.${os}-${arch}`;
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
  },

  // Tag from the GitHub release, binary from dl.k8s.io — version only, and the
  // external keeps building the download URL from it.
  kubectl: { kind: "githubRelease", source: "kubernetes/kubernetes" },

  // As kubectl: tag from GitHub, archive from get.helm.sh.
  helm: { kind: "githubRelease", source: "helm/helm" },

  /* ---------- ai-agents.toml tools ---------- */

  "agent-browser": {
    kind: "githubRelease",
    source: "vercel-labs/agent-browser",
    // Bare per-platform binaries; linux ships glibc AND static musl (KTD11).
    linuxMusl: true,
    asset: ({ os, arch, libc }) =>
      `agent-browser-${os}${libc === "musl" ? "-musl" : ""}-${x64Arch(arch)}`,
  },


  codegraph: {
    kind: "githubRelease",
    source: "colbymchenry/codegraph",
    asset: ({ os, arch }) => `codegraph-${os}-${x64Arch(arch)}.tar.gz`,
  },

  aoe: {
    kind: "githubRelease",
    source: "agent-of-empires/agent-of-empires",
    asset: ({ os, arch }) => `aoe-${os}-${arch}.tar.gz`,
  },

  /* ---------- version-only githubRelease entries ---------- */

  "compound-engineering": {
    kind: "githubRelease",
    source: "everyinc/compound-engineering-plugin",
    // The repo interleaves marketplace-* and cli-* tag trains, so
    // `releases/latest` would eventually resolve to the wrong one (KTD10).
    tagPrefix: "compound-engineering-",
  },

  /* ---------- gitlabRelease ---------- */

  // One key serves the vcs.toml binary and both bundled skills (AE5).
  glab: { kind: "gitlabRelease", source: "https://gitlab.com/api/v4/projects/34675721" },

  /* ---------- vendorManifest ---------- */

  agy: {
    kind: "vendorManifest",
    vendor: "antigravity",
    source: "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests",
  },

  "1password": {
    kind: "vendorManifest",
    vendor: "onePassword",
    source: "https://releases.1password.com/linux/stable/index.xml",
  },
  android: {
    kind: "vendorManifest",
    vendor: "android",
    source: "https://dl.google.com/android/cli/latest",
    emulatedPlatforms: ["linux-arm64"],
  },

  flutter: {
    kind: "vendorManifest",
    vendor: "flutter",
    source: "https://storage.googleapis.com/flutter_infra_release/releases",
    emulatedPlatforms: ["linux-arm64"],
  },

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

  "i-have-adhd": { kind: "gitRef", source: "ayghri/i-have-adhd", ref: "refs/heads/main" },

  "composition-patterns": {
    kind: "gitRef",
    source: "vercel-labs/agent-skills",
    ref: "refs/heads/main",
  },

  "react-best-practices": {
    kind: "gitRef",
    source: "vercel-labs/agent-skills",
    ref: "refs/heads/main",
  },

  "react-view-transitions": {
    kind: "gitRef",
    source: "vercel-labs/agent-skills",
    ref: "refs/heads/main",
  },

  "web-design-guidelines": {
    kind: "gitRef",
    source: "vercel-labs/agent-skills",
    ref: "refs/heads/main",
  },

  "writing-guidelines": {
    kind: "gitRef",
    source: "vercel-labs/agent-skills",
    ref: "refs/heads/main",
  },
};
