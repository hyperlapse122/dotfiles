/**
 * Timeout-bounded subprocess execution (plan KTD8, R15).
 *
 * Every subprocess the guard spawns runs on the tool-call path, so all of them
 * — the access probe and the `git remote` lookup alike — must be bounded. omp's
 * `pi.exec` documents no timeout option; its only cancellation surface is a
 * forwarded `AbortSignal`, so one timer both aborts the child and settles the
 * race. A timed-out or failed call resolves to `null`, which every caller
 * treats as undecidable and therefore blocking.
 */

export type ExecResult = { stdout: string; stderr: string; code: number; killed: boolean };

export type Exec = (
  command: string,
  args: string[],
  options?: { cwd?: string; signal?: AbortSignal },
) => Promise<ExecResult>;

/** Runs a command with an argv array — never a shell string — under a deadline. */
export type BoundedExec = (
  command: string,
  args: string[],
  options?: { cwd?: string },
) => Promise<ExecResult | null>;

export function createBoundedExec(exec: Exec, timeoutMs: number): BoundedExec {
  return async (command, args, options) => {
    const controller = new AbortController();
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        exec(command, args, { ...options, signal: controller.signal }),
        new Promise<null>((resolve) => {
          timer = setTimeout(() => {
            controller.abort();
            resolve(null);
          }, timeoutMs);
        }),
      ]);
    } catch {
      return null;
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  };
}
