import { spawn } from "node:child_process";

export type BrowserOpener = (url: URL) => Promise<void>;

export interface OpenBrowserOptions {
  platform?: NodeJS.Platform;
  spawnProcess?: typeof spawn;
  stderr?: { write(value: string): unknown };
}

export async function openBrowser(url: URL, options: OpenBrowserOptions = {}): Promise<void> {
  const platform = options.platform ?? process.platform;
  const command = platform === "darwin" ? "open" : platform === "linux" ? "xdg-open" : undefined;
  const stderr = options.stderr ?? process.stderr;
  const printable = url.toString();
  const printFallback = (): void => {
    stderr.write(`Open this authorization URL manually:\n${printable}\n`);
  };

  if (!command) {
    printFallback();
    throw new Error(`Unsupported platform for browser launch: ${platform}`);
  }

  const spawnProcess = options.spawnProcess ?? spawn;
  await new Promise<void>((resolve, reject) => {
    let child: ReturnType<typeof spawn>;
    let completed = false;
    let failureReported = false;

    const fail = (error: Error): void => {
      if (!failureReported) {
        failureReported = true;
        printFallback();
      }
      if (!completed) {
        completed = true;
        reject(error);
      }
    };

    try {
      child = spawnProcess(command, [printable], { detached: true, stdio: "ignore" });
    } catch (error) {
      fail(
        new Error(
          `Could not launch ${command}: ${error instanceof Error ? error.message : String(error)}`,
        ),
      );
      return;
    }

    child.once("error", (error) =>
      fail(new Error(`Could not launch ${command}: ${error.message}`)),
    );
    child.once("exit", (code, signal) => {
      if (code !== 0) {
        fail(new Error(`${command} failed (${signal ?? `exit ${String(code)}`})`));
      }
    });
    child.once("spawn", () => {
      child.unref();
      setImmediate(() => {
        if (completed) return;
        completed = true;
        resolve();
      });
    });
  });
}
