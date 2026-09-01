import { runOAuthFlow } from "./oauth.js";
import { OmpStorage } from "./storage/omp.js";

export const USAGE = "Usage: figma-auth\n";

export interface CliOptions {
  stderr?: { write(value: string): unknown };
  stdout?: { write(value: string): unknown };
  run?: (signal: AbortSignal) => Promise<void>;
}
export async function runCli(args: readonly string[], options: CliOptions = {}): Promise<number> {
  const stderr = options.stderr ?? process.stderr;
  const stdout = options.stdout ?? process.stdout;
  if (args.length !== 0) {
    stderr.write(USAGE);
    return 2;
  }

  const abort = new AbortController();
  const onSignal = (): void => abort.abort();
  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  try {
    const run =
      options.run ?? ((signal: AbortSignal) => runOAuthFlow({ adapter: new OmpStorage(), signal }));
    await run(abort.signal);
    stdout.write("Figma MCP credentials saved.\n");
    return 0;
  } catch (error) {
    stderr.write(`figma-auth: ${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  } finally {
    process.off("SIGINT", onSignal);
    process.off("SIGTERM", onSignal);
  }
}
