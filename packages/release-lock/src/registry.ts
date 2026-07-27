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

  kimi: {
    kind: "githubRelease",
    source: "MoonshotAI/kimi-code",
    // Tag shape is `@moonshot-ai/kimi-code@<semver>` (KTD10); assets are one
    // executable zip per platform.
    asset: ({ os, arch }) => `kimi-code-${win32Os(os)}-${x64Arch(arch)}.zip`,
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

  opencode: {
    kind: "githubRelease",
    source: "anomalyco/opencode",
    // linux ships .tar.gz; darwin and windows ship .zip. Upstream also
    // publishes musl and -baseline variants the consumer does not select.
    asset: ({ os, arch }) => `opencode-${os}-${x64Arch(arch)}${os === "linux" ? ".tar.gz" : ".zip"}`,
  },

  pi: {
    kind: "githubRelease",
    source: "earendil-works/pi",
    // Upstream ships windows .zip assets, but every consumer is POSIX-only
    // (the external skips windows; the linker script has no .ps1 counterpart),
    // so windows is deliberately not locked.
    asset: ({ os, arch }) => (os === "windows" ? null : `pi-${os}-${x64Arch(arch)}.tar.gz`),
  },

  codegraph: {
    kind: "githubRelease",
    source: "colbymchenry/codegraph",
    // win32 assets are .zip, not the .tar.gz today's template names on windows
    // (that render is broken upstream); the lock records what the release
    // actually publishes.
    asset: ({ os, arch }) => `codegraph-${win32Os(os)}-${x64Arch(arch)}${archiveExtension(os)}`,
  },

  aoe: {
    kind: "githubRelease",
    source: "agent-of-empires/agent-of-empires",
    // No windows build upstream; the external is gated the same way.
    asset: ({ os, arch }) => (os === "windows" ? null : `aoe-${os}-${arch}.tar.gz`),
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

  /* ---------- githubTag: the OpenCode latestTag plugin pins ---------- */

  // npm-installed plugins pinned to the newest GitHub tag with the leading
  // `v` stripped (KTD10), so consumers read the locked version verbatim.
  "oh-my-openagent": {
    kind: "githubTag",
    source: "code-yeongyu/oh-my-openagent",
    versionTransform: versionFromTag,
  },

  "opencode-wakatime": {
    kind: "githubTag",
    source: "angristan/opencode-wakatime",
    versionTransform: versionFromTag,
  },

  "@ex-machina/opencode-anthropic-auth": {
    kind: "githubTag",
    source: "ex-machina-co/opencode-anthropic-auth",
    versionTransform: versionFromTag,
  },

  /* ---------- gitlabRelease ---------- */

  // One key serves the vcs.toml binary and both bundled skills (AE5).
  glab: { kind: "gitlabRelease", source: "https://gitlab.com/api/v4/projects/34675721" },

  /* ---------- npm: the OpenCode npmLatest pin and the six pi extensions ---------- */

  "@oyng/opencode-agy-auth": { kind: "npm", source: "@oyng/opencode-agy-auth" },
  "@gotgenes/pi-anthropic-auth": { kind: "npm", source: "@gotgenes/pi-anthropic-auth" },
  "pi-mcp-extension": { kind: "npm", source: "pi-mcp-extension" },
  "pi-subagents": { kind: "npm", source: "pi-subagents" },
  "pi-ask-user": { kind: "npm", source: "pi-ask-user" },
  "@ff-labs/pi-fff": { kind: "npm", source: "@ff-labs/pi-fff" },
  "@ff-labs/fff-bun": { kind: "npm", source: "@ff-labs/fff-bun" },

  /* ---------- vendorManifest ---------- */

  claude: {
    kind: "vendorManifest",
    vendor: "claude",
    source: "https://downloads.claude.ai/claude-code-releases",
  },

  agy: {
    kind: "vendorManifest",
    vendor: "antigravity",
    source: "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests",
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

  // pi installs compound-engineering as a native `git:` source tracking the
  // default branch; the update-pi-extensions trigger bakes its HEAD sha.
  "pi-compound-engineering": {
    kind: "gitRef",
    source: "EveryInc/compound-engineering-plugin",
    ref: "HEAD",
  },
};
