import { lstat, readdir, readFile, readlink, stat } from "node:fs/promises";
import { join } from "node:path";

export interface ProcessRoots {
  paths: Set<string>;
  inodes: Set<string>;
  uncertain: boolean;
}

export async function scanLinuxRoots(procRoot: string = "/proc"): Promise<ProcessRoots> {
  const paths = new Set<string>();
  const inodes = new Set<string>();
  let uncertain = false;

  const currentUid = typeof process.getuid === "function" ? process.getuid() : undefined;

  let entries: string[];
  try {
    entries = await readdir(procRoot);
  } catch {
    return { paths, inodes, uncertain: true };
  }

  for (const entry of entries) {
    if (!/^[0-9]+$/.test(entry)) continue;
    const pidDir = join(procRoot, entry);

    if (currentUid !== undefined) {
      try {
        const st = await lstat(pidDir);
        if (st.uid !== currentUid) continue;
      } catch {
        continue;
      }
    }

    try {
      const exeLink = join(pidDir, "exe");
      try {
        const st = await stat(exeLink);
        inodes.add(`${st.dev}:${st.ino}`);
      } catch {}
      const exeTarget = await readlink(exeLink);
      if (exeTarget) {
        const cleanTarget = exeTarget.replace(/ \(deleted\)$/, "");
        paths.add(cleanTarget);
      }
    } catch {}

    try {
      const mapsFile = join(pidDir, "maps");
      const mapsContent = await readFile(mapsFile, "utf-8");
      for (const line of mapsContent.split("\n")) {
        const parts = line.trim().split(/\s+/);
        if (parts.length >= 6) {
          const mapPath = parts.slice(5).join(" ");
          if (mapPath.startsWith("/")) {
            const cleanPath = mapPath.replace(/ \(deleted\)$/, "");
            paths.add(cleanPath);
          }
        }
      }
    } catch {}

    try {
      const fdDir = join(pidDir, "fd");
      const fdEntries = await readdir(fdDir);
      for (const fd of fdEntries) {
        try {
          const fdLink = join(fdDir, fd);
          try {
            const st = await stat(fdLink);
            inodes.add(`${st.dev}:${st.ino}`);
          } catch {}
          const fdTarget = await readlink(fdLink);
          if (fdTarget && fdTarget.startsWith("/")) {
            const cleanFd = fdTarget.replace(/ \(deleted\)$/, "");
            paths.add(cleanFd);
          }
        } catch {}
      }
    } catch {}
  }

  return { paths, inodes, uncertain };
}
