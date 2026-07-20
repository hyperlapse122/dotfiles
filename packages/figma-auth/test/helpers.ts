import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const scratchRoot = join(
  process.env.XDG_RUNTIME_DIR ?? join(homedir(), ".cache"),
  "agent-scratch",
  "figma-auth-tests",
);

export async function createScratch(prefix: string): Promise<string> {
  await mkdir(scratchRoot, { recursive: true, mode: 0o700 });
  return mkdtemp(join(scratchRoot, `${prefix}-`));
}

export async function removeScratch(path: string): Promise<void> {
  await rm(path, { recursive: true, force: true });
}
