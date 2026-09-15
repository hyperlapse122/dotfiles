import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

export interface BeforeAgentStartEvent {
  prompt: string;
  systemPrompt: string[];
}

export interface BeforeAgentStartResult {
  systemPrompt: string[];
}

export type BeforeAgentStartHandler = (
  event: BeforeAgentStartEvent,
) => BeforeAgentStartResult | Promise<BeforeAgentStartResult>;

export interface ExtensionAPI {
  on(event: "before_agent_start", handler: BeforeAgentStartHandler): void;
}

export interface HookResult {
  context: string | null;
  diagnostic?: string;
}

export const MANAGED_BLOCK_START = "<!-- dotfiles-orca:begin -->";
export const MANAGED_BLOCK_END = "<!-- dotfiles-orca:end -->";
export const HOOK_TIMEOUT_MS = 8_000;
const MAX_CONTEXT_BYTES = 2 * 1024 * 1024;

const HOOK_HARNESS = "omp";

function hookPath(): string {
  return (
    process.env.DOTFILES_ORCHESTRATION_HOOK ??
    join(homedir(), ".local", "libexec", "orchestration-hook")
  );
}

function stopChild(child: ReturnType<typeof spawn>): void {
  if (child.pid === undefined) return;
  const pid = child.pid;
  try {
    process.kill(-child.pid, "SIGTERM");
  } catch {
    try {
      child.kill("SIGTERM");
    } catch {
      return;
    }
  }
  const escalation = setTimeout(() => {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      child.kill("SIGKILL");
    }
  }, 250);
  escalation.unref();
  child.once("close", () => clearTimeout(escalation));
}

export function invokeHook(
  command = hookPath(),
  env: NodeJS.ProcessEnv = process.env,
  timeoutMs = HOOK_TIMEOUT_MS,
): Promise<HookResult> {
  if (timeoutMs <= 0) {
    return Promise.resolve({ context: null, diagnostic: "orchestration hook timed out" });
  }

  return new Promise((resolve) => {
    let settled = false;
    let stdout = "";
    let timer: ReturnType<typeof setTimeout> | undefined;
    const child = spawn(command, ["hook", "--harness", HOOK_HARNESS], {
      detached: true,
      env: { ...env },
      stdio: ["ignore", "pipe", "ignore"],
    });

    const finish = (result: HookResult): void => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      resolve(result);
    };

    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (settled) return;
      stdout += chunk;
      if (Buffer.byteLength(stdout) > MAX_CONTEXT_BYTES) {
        stopChild(child);
        finish({ context: null, diagnostic: "orchestration context exceeded its size limit" });
      }
    });
    child.once("error", (error: Error) => {
      finish({ context: null, diagnostic: `orchestration hook failed: ${error.message}` });
    });
    child.once("close", (code, signal) => {
      if (code === 0) {
        finish(
          stdout === "" && env.ORCA_TERMINAL_HANDLE
            ? { context: null, diagnostic: "managed session received no orchestration context" }
            : { context: stdout === "" ? null : stdout },
        );
        return;
      }
      const status = code === null ? `signal ${signal ?? "unknown"}` : `exit ${code}`;
      finish({ context: null, diagnostic: `orchestration hook failed with ${status}` });
    });
    timer = setTimeout(() => {
      stopChild(child);
      finish({ context: null, diagnostic: `orchestration hook timed out after ${timeoutMs}ms` });
    }, timeoutMs);
  });
}

interface BlockRemoval {
  text: string;
  count: number;
}

function removeManagedBlocks(text: string): BlockRemoval | null {
  let cursor = 0;
  let count = 0;
  let result = "";
  for (;;) {
    const start = text.indexOf(MANAGED_BLOCK_START, cursor);
    if (start < 0) {
      result += text.slice(cursor);
      return { text: result, count };
    }
    const contentStart = start + MANAGED_BLOCK_START.length;
    const end = text.indexOf(MANAGED_BLOCK_END, contentStart);
    if (end < 0) return null;
    result += text.slice(cursor, start);
    cursor = end + MANAGED_BLOCK_END.length;
    count++;
  }
}

export function replaceManagedBlock(
  systemPrompt: readonly string[],
  context: string | null,
): string[] | null {
  const cleaned: string[] = [];
  for (const part of systemPrompt) {
    const removal = removeManagedBlocks(part);
    if (removal === null) return null;
    if (removal.text !== "" || removal.count === 0) cleaned.push(removal.text);
  }

  if (context === null) return cleaned;
  if (context.includes(MANAGED_BLOCK_START) || context.includes(MANAGED_BLOCK_END)) return null;
  cleaned.push(`${MANAGED_BLOCK_START}\n${context}\n${MANAGED_BLOCK_END}`);
  return cleaned;
}

export default async function dotfilesOrca(api: ExtensionAPI): Promise<void> {
  api.on("before_agent_start", async (event) => {
    const result = await invokeHook();
    if (result.diagnostic !== undefined) {
      console.error(`dotfiles-orca: ${result.diagnostic}`);
    }

    const systemPrompt = replaceManagedBlock(event.systemPrompt, result.context);
    if (systemPrompt === null) {
      console.error("dotfiles-orca: malformed managed block in system prompt");
      return { systemPrompt: event.systemPrompt.slice() };
    }
    return { systemPrompt };
  });
}
