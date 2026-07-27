/**
 * Platform vocabulary shared by every resolver.
 *
 * The string maps mirror the `replace` chains the chezmoi templates use today
 * (`.chezmoiexternals/*.toml`). They are reproduced here rather than invented so
 * a migrated external resolves byte-identical URLs to the pre-migration render.
 */

export const OPERATING_SYSTEMS = ["linux", "darwin", "windows"] as const;
export const ARCHITECTURES = ["amd64", "arm64"] as const;

export type OperatingSystem = (typeof OPERATING_SYSTEMS)[number];
export type Architecture = (typeof ARCHITECTURES)[number];

/** Lock key for one build target, e.g. `linux-amd64`. */
export type PlatformKey = `${OperatingSystem}-${Architecture}`;

export interface Platform {
  readonly os: OperatingSystem;
  readonly arch: Architecture;
}

export function platformKey({ os, arch }: Platform): PlatformKey {
  return `${os}-${arch}`;
}

export const ALL_PLATFORMS: readonly Platform[] = OPERATING_SYSTEMS.flatMap((os) =>
  ARCHITECTURES.map((arch) => ({ os, arch })),
);

/** `""` on unix, `".exe"` on windows. */
export function executableExtension(os: OperatingSystem): string {
  return os === "windows" ? ".exe" : "";
}

/** `.tar.gz` on unix, `.zip` on windows — the majority convention. */
export function archiveExtension(os: OperatingSystem): string {
  return os === "windows" ? ".zip" : ".tar.gz";
}

/** Rust target-triple arch component. */
export function rustArch(arch: Architecture): string {
  return arch === "amd64" ? "x86_64" : "aarch64";
}

/** Rust target-triple platform component, glibc flavour on linux. */
export function rustTarget(os: OperatingSystem): string {
  switch (os) {
    case "linux":
      return "unknown-linux-gnu";
    case "darwin":
      return "apple-darwin";
    case "windows":
      return "pc-windows-msvc";
  }
}

/** As `rustTarget`, but the static-musl linux flavour some projects publish. */
export function muslTarget(os: OperatingSystem): string {
  return os === "linux" ? "unknown-linux-musl" : rustTarget(os);
}

/** Strip a single leading `v` from a tag; tags without one are returned as-is. */
export function versionFromTag(tag: string): string {
  return tag.startsWith("v") ? tag.slice(1) : tag;
}
