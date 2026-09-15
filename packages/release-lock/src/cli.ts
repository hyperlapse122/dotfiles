import { fileURLToPath } from "node:url";
import { resolveAll } from "./resolve-all.js";
import { REGISTRY } from "./registry.js";
import { mergeLocks, pruneRetiredPlatforms, readLock, serializeLock, writeLock } from "./lock.js";

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
  resolve?: typeof resolveAll;
}

type Output = { kind: "file"; path: string } | { kind: "stdout"; path: string };

function argumentsFor(
  argv: readonly string[],
  defaultPath: string,
): { output: Output; only: string | undefined; pruneRetired: boolean } | null {
  let output: Output | undefined;
  let only: string | undefined;
  let pruneRetired = false;
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === "--prune-retired") {
      if (pruneRetired) return null;
      pruneRetired = true;
    } else if (flag === "--stdout") {
      if (output) return null;
      output = { kind: "stdout", path: defaultPath };
    } else if (flag === "--out" || flag === "--only") {
      const value = argv[++index];
      if (!value || value.startsWith("--")) return null;
      if (flag === "--out") {
        if (output) return null;
        output = { kind: "file", path: value };
      } else {
        if (only !== undefined || !Object.hasOwn(REGISTRY, value)) return null;
        only = value;
      }
    } else {
      return null;
    }
  }
  if (pruneRetired && only !== undefined) return null;
  return { output: output ?? { kind: "file", path: defaultPath }, only, pruneRetired };
}

export async function runCli(argv: readonly string[], options: CliOptions = {}): Promise<number> {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;
  const args = argumentsFor(argv, options.defaultPath ?? DEFAULT_LOCK_PATH);
  if (!args) {
    stderr.write(
      "Usage: release-lock [--only <registered-tool> | --prune-retired] [--out <path> | --stdout]\n",
    );
    return 2;
  }

  const { output, only, pruneRetired } = args;
  const registry = only === undefined ? REGISTRY : { [only]: REGISTRY[only]! };
  const existing = await readLock(output.path);
  if (pruneRetired) {
    if (existing === null) {
      stderr.write("release-lock: pruning requires an existing lock\n");
      return 1;
    }
    const complete = {
      releases: {
        tools: Object.fromEntries(
          Object.entries(existing.releases.tools).filter(([name]) => Object.hasOwn(REGISTRY, name)),
        ),
      },
    };
    if (output.kind === "stdout") stdout.write(serializeLock(complete));
    else await writeLock(output.path, complete);
    return 0;
  }
  const { lock, failures } = await (options.resolve ?? resolveAll)(githubToken(), registry);
  const complete =
    only === undefined
      ? pruneRetiredPlatforms(failures.length === 0 ? lock : mergeLocks(existing, lock))
      : mergeLocks(existing, pruneRetiredPlatforms(lock));

  for (const failure of failures) stderr.write(`release-lock: ${failure}\n`);

  if (output.kind === "stdout") stdout.write(serializeLock(complete));
  else await writeLock(output.path, complete);

  return failures.length > 0 ? 1 : 0;
}

if (import.meta.main) {
  try {
    process.exitCode = await runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(
      `release-lock: ${error instanceof Error ? error.message : String(error)}\n`,
    );
    process.exitCode = 1;
  }
}
