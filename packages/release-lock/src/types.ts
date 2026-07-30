import type { Platform, PlatformKey } from "./platforms.js";

/** A resolution failure that names its source, shared by every resolver kind. */
export class ResolutionError extends Error {
  constructor(source: string, detail: string) {
    super(`${source}: ${detail}`);
    this.name = "ResolutionError";
  }
}

/** One downloadable artifact, fully resolved. */
export interface LockedArtifact {
  readonly url: string;
  /** Lowercase hex sha256, or null when the source publishes no digest. */
  readonly sha256: string | null;
  /** Byte size of the artifact, where the source publishes one (claude). */
  readonly size?: number;
  /** Present when this target borrows the amd64 build and runs it emulated. */
  readonly emulated?: true;
}

/** One tool's entry in the lock. */
export interface LockedTool {
  readonly kind: ResolverKind;
  readonly source: string;
  /** The upstream tag or version, verbatim (leading `v` preserved when present). */
  readonly version: string;
  /**
   * npm `dist.integrity` (sha512-base64), recorded as published for
   * completeness. Version-only for consumers: chezmoi cannot verify an npm
   * subresource integrity string.
   */
  readonly integrity?: string | null;
  /**
   * ociImage only: the manifest digest of the tracked tag (`sha256:<hex>`),
   * platform-free — a multi-arch manifest list digest covers every platform.
   */
  readonly digest?: string;
  /** Absent for tools whose consumers only need a version. */
  readonly artifacts?: Readonly<Partial<Record<PlatformKey, LockedArtifact>>>;
}

export interface ReleaseLock {
  /**
   * Nested under `releases` because chezmoi merges every `.chezmoidata` file's
   * contents at the top level — a bare `tools` key would land in template data
   * as the collision-prone `.tools` instead of `.releases.tools`.
   */
  readonly releases: {
    readonly tools: Readonly<Record<string, LockedTool>>;
  };
}

export type ResolverKind =
  | "githubRelease"
  | "githubTag"
  | "gitlabRelease"
  | "npm"
  | "vendorManifest"
  | "gitRef"
  | "ociImage";

/** The vendor endpoints the vendorManifest kind knows how to read. */
export type VendorName = "claude" | "winbox";

/**
 * Asset selection for one tool.
 *
 * Returns the upstream asset filename for a platform, or null when the tool
 * publishes nothing for it (jq is darwin-only, for example).
 */
export type AssetSelector = (platform: Platform, tag: string) => string | null;

export interface ToolSpec {
  readonly kind: ResolverKind;
  /**
   * `owner/repo` for the GitHub kinds and gitRef, the package name for npm,
   * and the endpoint base URL for gitlabRelease and vendorManifest.
   */
  readonly source: string;
  /** Omit for version-only tools — no artifacts block is emitted. */
  readonly asset?: AssetSelector;
  /** Declared, never inferred — so a stale asset pattern cannot hide behind a silent skip. */
  readonly emulatedPlatforms?: readonly PlatformKey[];
  /**
   * githubRelease only: resolve the newest release whose tag carries this
   * prefix instead of `releases/latest` (KTD10 — compound-engineering's repo
   * interleaves marketplace-*, cli-* tag trains).
   */
  readonly tagPrefix?: string;
  /**
   * githubRelease only: the tool publishes distinct static-musl linux builds;
   * resolve them into the `-musl` lock keys next to the glibc ones (KTD11).
   */
  readonly linuxMusl?: boolean;
  /** vendorManifest only: which vendor endpoint shape to read. */
  readonly vendor?: VendorName;
  /** gitRef only: the ref to resolve, e.g. `refs/heads/main` or `HEAD`. */
  readonly ref?: string;
  /**
   * ociImage only: the image tag to track, e.g. `latest`. `source` carries
   * the full `registry/repository` path (`docker.io/eceasy/cli-proxy-api`).
   */
  readonly tag?: string;
  /**
   * KTD10 tag-shape transform applied to the resolved tag before it is
   * recorded (e.g. stripping the leading `v` for an npm-pinned plugin), so
   * consumers read the locked version verbatim.
   */
  readonly versionTransform?: (tag: string) => string;
}

export type Registry = Readonly<Record<string, ToolSpec>>;
