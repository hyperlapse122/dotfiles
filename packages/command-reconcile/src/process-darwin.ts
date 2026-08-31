import { lstat } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ProcessRoots } from "./process-linux.js";

const execFileAsync = promisify(execFile);

export async function scanDarwinRoots(): Promise<ProcessRoots> {
  const paths = new Set<string>();
  const inodes = new Set<string>();

  const currentUid = typeof process.getuid === "function" ? process.getuid() : undefined;
  const args = ["-n", "-P", "-F", "n"];
  if (currentUid !== undefined) {
    args.unshift("-u", String(currentUid));
  }

  try {
    const { stdout } = await execFileAsync("lsof", args, { timeout: 5000 });
    for (const line of stdout.split("\n")) {
      if (line.startsWith("n/")) {
        const filePath = line.slice(1);
        paths.add(filePath);
        try {
          const st = await lstat(filePath);
          inodes.add(`${st.dev}:${st.ino}`);
        } catch {}
      }
    }
    return { paths, inodes, uncertain: false };
  } catch {
    return { paths, inodes, uncertain: true };
  }
}
