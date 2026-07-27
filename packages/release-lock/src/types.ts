import type { Platform, PlatformKey } from "./platforms.js";

/** One downloadable artifact, fully resolved. */
export interface LockedArtifact {
  readonly url: string;
  /** Lowercase hex sha256, or null when the source publishes no digest. */
  readonly sha256: string | null;
  /** Present when this target borrows the amd64 build and runs it emulated. */
  readonly emulated?: true;
}

/** One tool's entry in the lock. */
export interface LockedTool {
  readonly kind: ResolverKind;
  readonly source: string;
  /** The upstream tag or version, verbatim (leading `v` preserved when present). */
  readonly version: string;
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
  | "gitRef";

/**
 * Asset selection for one tool.
 *
 * Returns the upstream asset filename for a platform, or null when the tool
 * publishes nothing for it (jq is darwin-only, for example).
 */
export type AssetSelector = (platform: Platform, tag: string) => string | null;

export interface ToolSpec {
  readonly kind: ResolverKind;
  /** `owner/repo` for GitHub kinds. */
  readonly source: string;
  /** Omit for version-only tools — no artifacts block is emitted. */
  readonly asset?: AssetSelector;
  /** Declared, never inferred — so a stale asset pattern cannot hide behind a silent skip. */
  readonly emulatedPlatforms?: readonly PlatformKey[];
}

export type Registry = Readonly<Record<string, ToolSpec>>;
