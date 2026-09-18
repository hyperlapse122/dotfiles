import { fileURLToPath } from "node:url";
import { resolveAll } from "./resolve-all.js";
import { REGISTRY } from "./registry.js";
import { mergeLocks, pruneRetiredPlatforms, readLock, serializeLock, writeLock } from "./lock.js";

export const DEFAULT_LOCK_PATH = fileURLToPath(
  new URL("../../../home/.chezmoidata/releases.json", import.meta.url),
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

interface Restore {
  tool: string;
  from: string;
}

function argumentsFor(
  argv: readonly string[],
  defaultPath: string,
): {
  output: Output;
  only: string | undefined;
  pruneRetired: boolean;
  restore: Restore | undefined;
} | null {
  let output: Output | undefined;
  let only: string | undefined;
  let pruneRetired = false;
  let restoreTool: string | undefined;
  let restoreFrom: string | undefined;
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === "--prune-retired") {
      if (pruneRetired) return null;
      pruneRetired = true;
    } else if (flag === "--stdout") {
      if (output) return null;
      output = { kind: "stdout", path: defaultPath };
    } else if (
      flag === "--out" ||
      flag === "--only" ||
      flag === "--restore-tool" ||
      flag === "--from"
    ) {
      const value = argv[++index];
      if (!value || value.startsWith("--")) return null;
      if (flag === "--out") {
        if (output) return null;
        output = { kind: "file", path: value };
      } else if (flag === "--from") {
        if (restoreFrom !== undefined) return null;
        restoreFrom = value;
      } else {
        if (!Object.hasOwn(REGISTRY, value)) return null;
        if (flag === "--only") {
          if (only !== undefined) return null;
          only = value;
        } else {
          if (restoreTool !== undefined) return null;
          restoreTool = value;
        }
      }
    } else {
      return null;
    }
  }
  if (pruneRetired && only !== undefined) return null;
  if ((restoreTool === undefined) !== (restoreFrom === undefined)) return null;
  const restore =
    restoreTool !== undefined && restoreFrom !== undefined
      ? { tool: restoreTool, from: restoreFrom }
      : undefined;
  if (restore && (only !== undefined || pruneRetired)) return null;
  return { output: output ?? { kind: "file", path: defaultPath }, only, pruneRetired, restore };
}

export async function runCli(argv: readonly string[], options: CliOptions = {}): Promise<number> {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;
  const args = argumentsFor(argv, options.defaultPath ?? DEFAULT_LOCK_PATH);
  if (!args) {
    stderr.write(
      "Usage: release-lock [--only <registered-tool> | --prune-retired | --restore-tool <registered-tool> --from <lock>] [--out <path> | --stdout]\n",
    );
    return 2;
  }

  const { output, only, pruneRetired, restore } = args;
  const registry = only === undefined ? REGISTRY : { [only]: REGISTRY[only]! };
  const existing = await readLock(output.path);
  if (restore) {
    const source = await readLock(restore.from);
    if (existing === null || source === null) {
      stderr.write(
        `release-lock: restoring requires an existing lock: ${existing === null ? output.path : restore.from}\n`,
      );
      return 1;
    }
    const restored = source.releases.tools[restore.tool];
    if (restored === undefined) {
      stderr.write(`release-lock: ${restore.tool} is not in ${restore.from}\n`);
      return 1;
    }
    const complete = mergeLocks(existing, { releases: { tools: { [restore.tool]: restored } } });
    if (output.kind === "stdout") stdout.write(serializeLock(complete));
    else await writeLock(output.path, complete);
    return 0;
  }
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
