import type { Hooks, Plugin, PluginInput } from "@opencode-ai/plugin";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, normalize, resolve, sep } from "node:path";

/**
 * Enforcement mode, read once from the `OPENCODE_SCRATCH_GUARD` environment
 * variable when the plugin loads:
 *
 * - `enforce` (default) — deny reads/writes/executes under the shared system
 *   temp by throwing from `tool.execute.before`, which aborts the tool call and
 *   surfaces the reason to the model.
 * - `warn` — allow the operation but attach a warning (`output.message`) that
 *   surfaces to the model. `$TMPDIR` is still injected.
 * - `off` — disable the plugin entirely: no injection, no guard.
 *
 * The variable is read from the OpenCode runtime's environment (not a per-command
 * env), so an agent cannot flip it inline in a shell command — only the user can,
 * by exporting it before launching OpenCode.
 */
export type GuardMode = "enforce" | "warn" | "off";

const SERVICE = "scratch-guard";
const SCRATCH_SUBDIR = "agent-scratch";
const ENV_MODE = "OPENCODE_SCRATCH_GUARD";

/** Tools whose single file-path argument is checked against the denied roots. */
const FILE_PATH_TOOLS = new Set(["read", "write", "edit"]);

export function parseMode(raw: string | undefined): GuardMode {
  switch ((raw ?? "").trim().toLowerCase()) {
    case "off":
    case "0":
    case "false":
      return "off";
    case "warn":
      return "warn";
    default:
      return "enforce";
  }
}

/**
 * The shared system-temp roots AGENTS.md denies. Empty on Windows, whose
 * `%TEMP%` is already per-user, so there is no shared temp to guard. On macOS
 * `/tmp` and `/var` are symlinked under `/private`, so the realpath forms are
 * denied too.
 */
export function deniedRoots(platform: NodeJS.Platform = process.platform): readonly string[] {
  if (platform === "win32") return [];
  const roots = ["/tmp", "/var/tmp", "/dev/shm"];
  if (platform === "darwin") roots.push("/private/tmp", "/private/var/tmp");
  return roots;
}

/**
 * The per-user scratch directory to inject as `$TMPDIR`. Uses the platform's
 * per-user temp base (Linux `$XDG_RUNTIME_DIR`, macOS `$TMPDIR`, Windows
 * `%TEMP%`), falling back to a guaranteed-per-user path that is NEVER the shared
 * `/tmp` — deliberately not `os.tmpdir()`, which returns `/tmp` on Linux.
 */
export function computeScratchDir(
  env: NodeJS.ProcessEnv,
  platform: NodeJS.Platform,
  home: string | undefined,
): string {
  const configured =
    platform === "win32"
      ? (env["TEMP"] ?? env["TMP"])
      : platform === "darwin"
        ? env["TMPDIR"]
        : env["XDG_RUNTIME_DIR"];
  const envHome = platform === "win32" ? (env["USERPROFILE"] ?? env["HOME"]) : env["HOME"];
  const effectiveHome =
    home && home.length > 0 ? home : envHome && envHome.length > 0 ? envHome : undefined;
  const base =
    configured && configured.length > 0
      ? configured
      : effectiveHome !== undefined
        ? platform === "win32"
          ? resolve(effectiveHome, "AppData", "Local", "Temp")
          : resolve(effectiveHome, ".cache")
        : resolve(process.cwd(), ".cache");
  return resolve(base, SCRATCH_SUBDIR);
}

function toAbsolute(filePath: string, baseDir: string): string {
  return normalize(isAbsolute(filePath) ? filePath : resolve(baseDir, filePath));
}

/** True when `filePath` resolves to a location at or under a denied system-temp root. */
export function isDeniedPath(
  filePath: string,
  platform: NodeJS.Platform,
  baseDir: string,
): boolean {
  const abs = toAbsolute(filePath, baseDir);
  return deniedRoots(platform).some((root) => abs === root || abs.startsWith(root + sep));
}

/**
 * A regex matching any denied root as the start of an absolute path token in a
 * shell command: preceded by a delimiter — NOT a word char, `/`, or `.` (so
 * `/home/x/tmp`, `./tmp`, and `foo/tmp` do NOT match) — and NOT followed by a
 * word char (so `/tmp`, `/tmp/x`, `>/tmp`, and `TMPDIR=/tmp` match, but `/tmpfs`
 * does not). Returns `null` on platforms with no shared temp to guard.
 */
export function makeBashDenyRegex(platform: NodeJS.Platform = process.platform): RegExp | null {
  const roots = deniedRoots(platform);
  if (roots.length === 0) return null;
  const alternation = [...roots]
    .sort((a, b) => b.length - a.length)
    .map((root) => root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("|");
  return new RegExp(`(?<![\\w/.])(?:${alternation})(?![\\w])`);
}

function resolveFilePath(args: Record<string, unknown>): string | undefined {
  const raw = args["filePath"] ?? args["path"] ?? args["file_path"];
  return typeof raw === "string" ? raw : undefined;
}

export const ScratchGuardPlugin: Plugin = async ({
  client,
  directory,
}: PluginInput): Promise<Hooks> => {
  const platform = process.platform;
  const mode = parseMode(process.env[ENV_MODE]);
  const home = homedir();
  if (home === undefined || home.length === 0) {
    await client.app
      .log({
        body: {
          service: SERVICE,
          level: "warn",
          message:
            "could not determine user home directory; falling back to process.cwd() for the scratch dir",
        },
      })
      .catch(() => {});
  }
  const scratchDir = computeScratchDir(process.env, platform, home);
  const bashDenyRe = makeBashDenyRegex(platform);
  const baseDir = directory && directory.length > 0 ? directory : process.cwd();

  if (mode === "off") return {};

  // Ensure the injected $TMPDIR exists so `mktemp` and friends land there.
  try {
    mkdirSync(scratchDir, { recursive: true, mode: 0o700 });
  } catch (error) {
    await client.app
      .log({
        body: {
          service: SERVICE,
          level: "warn",
          message: `could not create scratch dir ${scratchDir}; $TMPDIR injection may fail`,
          extra: { error: String(error) },
        },
      })
      .catch(() => {});
  }

  const reason = (target: string): string =>
    `[${SERVICE}] Blocked: "${target}" is under the shared system temp ` +
    `(${deniedRoots(platform).join(", ")}), which AGENTS.md denies. Write throwaway ` +
    `scratch to the per-user dir instead — it is injected as $TMPDIR (currently ` +
    `"${scratchDir}") — or prefer a git-ignored path inside the workspace. See ` +
    `AGENTS.md "Temporary / scratch files".`;

  return {
    // Inject the per-user scratch dir as $TMPDIR into every shell command, so
    // `mktemp`, and any TMPDIR-aware tool, defaults its temp there instead of
    // the shared /tmp. On Windows also set TEMP/TMP to the same dir.
    "shell.env": async (_input, output) => {
      output.env["TMPDIR"] = scratchDir;
      if (platform === "win32") {
        output.env["TEMP"] = scratchDir;
        output.env["TMP"] = scratchDir;
      }
    },
    // Guard the write/execute (and read) vectors: bash commands referencing a
    // denied root, and read/write/edit whose file path resolves under one.
    "tool.execute.before": async (
      input: { tool: string; sessionID: string; callID: string },
      output: { args: Record<string, unknown>; message?: string },
    ): Promise<void> => {
      const tool = input.tool?.toLowerCase();
      const args = output.args ?? {};
      let target: string | undefined;

      if (tool === "bash") {
        const command = args["command"];
        if (bashDenyRe && typeof command === "string") {
          const hit = bashDenyRe.exec(command);
          if (hit) target = hit[0];
        }
      } else if (tool && FILE_PATH_TOOLS.has(tool)) {
        const filePath = resolveFilePath(args);
        if (filePath && isDeniedPath(filePath, platform, baseDir)) target = filePath;
      }

      if (target === undefined) return;

      if (mode === "warn") {
        output.message = reason(target);
        return;
      }
      throw new Error(reason(target));
    },
  };
};
