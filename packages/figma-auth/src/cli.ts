import { runOAuthFlow } from "./oauth.js";
import { AntigravityStorage } from "./storage/antigravity.js";
import { OpenCodeStorage } from "./storage/opencode.js";
import { PiStorage } from "./storage/pi.js";
import { KimiStorage } from "./storage/kimi.js";
import type { StorageAdapter } from "./storage/types.js";

const TARGETS = ["opencode", "pi", "antigravity", "kimi"] as const;
export type AuthTarget = (typeof TARGETS)[number];
export const USAGE = "Usage: figma-auth <opencode|pi|antigravity|kimi>\n";

export interface CliOptions {
  stderr?: { write(value: string): unknown };
  stdout?: { write(value: string): unknown };
  run?: (target: AuthTarget, signal: AbortSignal) => Promise<void>;
}

export function parseTarget(args: readonly string[]): AuthTarget | undefined {
  if (args.length !== 1) return undefined;
  return TARGETS.includes(args[0] as AuthTarget) ? (args[0] as AuthTarget) : undefined;
}

export function adapterFor(target: AuthTarget): StorageAdapter {
  switch (target) {
    case "opencode":
      return new OpenCodeStorage();
    case "pi":
      return new PiStorage();
    case "antigravity":
      return new AntigravityStorage();
    case "kimi":
      return new KimiStorage();
  }
}

export async function runCli(args: readonly string[], options: CliOptions = {}): Promise<number> {
  const stderr = options.stderr ?? process.stderr;
  const stdout = options.stdout ?? process.stdout;
  const target = parseTarget(args);
  if (!target) {
    stderr.write(USAGE);
    return 2;
  }

  const abort = new AbortController();
  const onSignal = (): void => abort.abort();
  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  try {
    const run =
      options.run ??
      ((selected: AuthTarget, signal: AbortSignal) =>
        runOAuthFlow({ adapter: adapterFor(selected), signal }));
    await run(target, abort.signal);
    stdout.write(`Figma MCP credentials saved for ${target}.\n`);
    return 0;
  } catch (error) {
    stderr.write(`figma-auth: ${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  } finally {
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
  }
}
