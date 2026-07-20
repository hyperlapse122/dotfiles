import { runOAuthFlow } from "./oauth.js";
import { OpenCodeStorage } from "./storage/opencode.js";
import { PiStorage } from "./storage/pi.js";

export type AuthTarget = "opencode" | "pi";
export const USAGE = "Usage: figma-auth <opencode|pi>\n";

export interface CliOptions {
  stderr?: { write(value: string): unknown };
  stdout?: { write(value: string): unknown };
  run?: (target: AuthTarget, signal: AbortSignal) => Promise<void>;
}

export function parseTarget(args: readonly string[]): AuthTarget | undefined {
  if (args.length !== 1) return undefined;
  return args[0] === "opencode" || args[0] === "pi" ? args[0] : undefined;
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
        runOAuthFlow({
          adapter: selected === "opencode" ? new OpenCodeStorage() : new PiStorage(),
          signal,
        }));
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
