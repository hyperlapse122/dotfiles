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
          return `marksman-linux-${arch === "amd64" ? "x64" : arch}`;
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
};
