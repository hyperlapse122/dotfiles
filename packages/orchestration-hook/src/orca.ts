/**
 * Reading the version-matched orchestration guide from the installed Orca CLI.
 *
 * Two hazards the retired bash watchdog recorded, both preserved here:
 *
 * `orca` is Orca's own CLI on macOS, but on Linux it resolves through PATH to
 * /usr/bin/orca, the GNOME screen reader, and running it would start speech in
 * the user's session. Only a confirmed Darwin honours the bare name: an absent
 * or unreadable `uname` remaps, because starting a screen reader is the worse
 * of the two failures.
 *
 * The CLI is a launcher whose child holds the pipe. Signalling the direct child
 * alone leaves that descendant alive holding this process's stdout, which
 * stalls a reader waiting for EOF for the full deadline after the hook has
 * already exited. Terminating the whole process group is what closes it.
 */

import { spawn } from "node:child_process";

export interface ResolveOrcaOptions {
  /** Operator-supplied command, from ORCA_CLI_COMMAND. */
  configured?: string | undefined;
  /**
   * Reads `uname -s`, or returns undefined when it could not be read.
   *
   * A thunk, not a value: only the screen-reader branch consults it, and that
   * branch needs an explicitly configured `orca`. With ORCA_CLI_COMMAND unset —
   * the normal case — an eager read would fork a process on every lead session
   * start and discard the result, on the very path this package exists to take
   * a shell off.
   */
  platform?: (() => string | undefined) | undefined;
}

const SCREEN_READER_NAMES = new Set(["orca", "/usr/bin/orca"]);
const SAFE_CLI = "orca-ide";

/** The Orca executable this host may safely run. */
export function resolveOrcaCommand(options: ResolveOrcaOptions): string {
  const configured = options.configured ?? "";
  if (configured === "") return SAFE_CLI;
  if (!SCREEN_READER_NAMES.has(configured)) return configured;
  return options.platform?.() === "Darwin" ? configured : SAFE_CLI;
}

export interface FetchGuideOptions {
  command: string;
  /** Milliseconds remaining for the whole run, shared with every other step. */
  deadlineMs: number;
}

/**
 * Run `<command> skills get orchestration` and return its stdout.
 *
 * Returns null on a non-zero exit, empty output, a spawn failure, or the
 * deadline — every one of which the caller turns into no envelope rather than
 * a partial one.
 */
export async function fetchGuide(options: FetchGuideOptions): Promise<string | null> {
  if (options.deadlineMs <= 0) return null;

  return await new Promise<string | null>((resolve) => {
    let settled = false;
    const chunks: Buffer[] = [];

    // `detached` puts the child in its own process group so the kill below
    // reaches the launcher's children too.
    const child = spawn(options.command, ["skills", "get", "orchestration"], {
      detached: true,
      stdio: ["ignore", "pipe", "ignore"],
    });

    const finish = (guide: string | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(guide);
    };

    const killGroup = () => {
      if (child.pid === undefined) return;
      try {
        process.kill(-child.pid, "SIGTERM");
      } catch {
        try {
          child.kill("SIGTERM");
        } catch {
          // The process is already gone; nothing holds the pipe.
        }
      }
    };

    const timer = setTimeout(() => {
      killGroup();
      finish(null);
    }, options.deadlineMs);

    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.on("error", () => finish(null));
    child.on("close", (code) => {
      if (code !== 0) return finish(null);
      const text = Buffer.concat(chunks).toString("utf8");
      finish(text.trim() === "" ? null : text);
    });
  });
}
