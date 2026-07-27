import { resolveAll } from "./resolve-all.js";
import { mergeLocks, readLock, serializeLock, writeLock } from "./lock.js";

/**
 * CLI entry — resolves every registered tool into the release lock.
 *
 * With `--out <path>` the resolution is overlaid onto the file already there and
 * written back; without it the lock goes to stdout. Either way a source that
 * fails to resolve is reported on stderr and omitted, so overlaying keeps its
 * last good entry rather than blanking it. Exit code 1 signals that at least one
 * source failed, whether or not anything was written.
 */

function githubToken(): string | undefined {
  const env = process.env;
  return env["CHEZMOI_GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_ACCESS_TOKEN"] ?? env["GITHUB_TOKEN"];
}

function outPath(argv: readonly string[]): string | undefined {
  const flag = argv.indexOf("--out");
  if (flag === -1) return undefined;
  const value = argv[flag + 1];
  if (value === undefined || value.startsWith("--")) throw new Error("--out requires a path");
  return value;
}

const destination = outPath(process.argv.slice(2));
const { lock, failures } = await resolveAll(githubToken());

for (const failure of failures) process.stderr.write(`release-lock: ${failure}\n`);

if (destination === undefined) process.stdout.write(serializeLock(lock));
else await writeLock(destination, mergeLocks(await readLock(destination), lock));

if (failures.length > 0) process.exitCode = 1;
