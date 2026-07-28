import { fileURLToPath } from "node:url";
import { resolveAll } from "./resolve-all.js";
import { mergeLocks, readLock, serializeLock, writeLock } from "./lock.js";
import type { ReleaseLock } from "./types.js";

/**
 * CLI entry — resolves every registered tool into the release lock.
 *
 * Plain invocation atomically refreshes the repository lock. `--out <path>`
 * refreshes another destination, while `--stdout` prints a merged inspection
 * result without writing. A partial resolution overlays the prior lock; a clean
 * resolution is authoritative and prunes retired tools.
 */

export const DEFAULT_LOCK_PATH = fileURLToPath(
  new URL("../../../.chezmoidata/releases.json", import.meta.url),
);

function githubToken(): string | undefined {
  const env = process.env;
  return env["CHEZMOI_GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_TOKEN"];
}

interface Writable {
  write(value: string): unknown;
}

interface CliOptions {
  defaultPath?: string;
  stdout?: Writable;
  stderr?: Writable;
  resolve?: (
    token: string | undefined,
  ) => Promise<{ lock: ReleaseLock; failures: string[] }>;
}

type Output = { kind: "file"; path: string } | { kind: "stdout"; path: string };

function outputFor(argv: readonly string[], defaultPath: string): Output | null {
  if (argv.length === 0) return { kind: "file", path: defaultPath };
  if (argv.length === 1 && argv[0] === "--stdout") {
    return { kind: "stdout", path: defaultPath };
  }
  const destination = argv[1];
  if (argv.length === 2 && argv[0] === "--out" && destination && !destination.startsWith("--")) {
    return { kind: "file", path: destination };
  }
  return null;
}

export async function runCli(argv: readonly string[], options: CliOptions = {}): Promise<number> {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;
  const output = outputFor(argv, options.defaultPath ?? DEFAULT_LOCK_PATH);
  if (!output) {
    stderr.write("Usage: release-lock [--out <path> | --stdout]\n");
    return 2;
  }

  const existing = await readLock(output.path);
  const { lock, failures } = await (options.resolve ?? resolveAll)(githubToken());
  const complete = failures.length === 0 ? lock : mergeLocks(existing, lock);

  for (const failure of failures) stderr.write(`release-lock: ${failure}\n`);

  if (output.kind === "stdout") stdout.write(serializeLock(complete));
  else await writeLock(output.path, complete);

  return failures.length > 0 ? 1 : 0;
}

if (import.meta.main) {
  try {
    process.exitCode = await runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`release-lock: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
