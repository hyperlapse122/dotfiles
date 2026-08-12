/**
 * Platform vocabulary shared by every resolver.
 *
 * The string maps match the replacement chains used by the chezmoi templates
 * (`.chezmoiexternals/*.toml`). Selectors preserve the expected asset URLs.
 */

export const OPERATING_SYSTEMS = ["linux", "darwin"] as const;
export const ARCHITECTURES = ["amd64", "arm64"] as const;

export type OperatingSystem = (typeof OPERATING_SYSTEMS)[number];
export type Architecture = (typeof ARCHITECTURES)[number];

/** Lock key for one build target, e.g. `linux-amd64` or `linux-amd64-musl`. */
export type PlatformKey = `${OperatingSystem}-${Architecture}` | `linux-${Architecture}-musl`;

export interface Platform {
  readonly os: OperatingSystem;
  readonly arch: Architecture;
  /** Set only on the linux static-musl targets (KTD11); absent means glibc. */
  readonly libc?: "musl";
}

export function platformKey({ os, arch, libc }: Platform): PlatformKey {
  // Only linux targets ever carry libc (MUSL_PLATFORMS), hence the cast.
  return libc === "musl" ? (`${os}-${arch}-musl` as PlatformKey) : `${os}-${arch}`;
}

export const ALL_PLATFORMS: readonly Platform[] = OPERATING_SYSTEMS.flatMap((os) =>
  ARCHITECTURES.map((arch) => ({ os, arch })),
);

/**
 * The linux static-musl targets, resolved only for tools that opt in via
 * `linuxMusl` — upstreams that publish a distinct musl build next to the glibc
 * one (agent-browser) get their own lock keys (KTD11).
 */
export const MUSL_PLATFORMS: readonly Platform[] = ARCHITECTURES.map((arch) => ({
  os: "linux" as const,
  arch,
  libc: "musl" as const,
}));

/**
 * Every platform a `linuxMusl` tool targets — `ALL_PLATFORMS` plus the musl
 * pair. The single source for "every currently-valid platform, musl
 * included" so `lock.ts`, `github.ts`, and `registry.test.ts` derive the
 * same union instead of each re-deriving `[...ALL_PLATFORMS, ...MUSL_PLATFORMS]`.
 */
export const ALL_PLATFORMS_WITH_MUSL: readonly Platform[] = [...ALL_PLATFORMS, ...MUSL_PLATFORMS];

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
