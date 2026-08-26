import { randomUUID } from "node:crypto";
import { lstat, mkdir, rename, rm, symlink } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";

export interface CommandPaths {
  home: string;
  binDir: string;
  libDir: string;
  storeDir: string;
  currentDir: string;
  quarantineDir: string;
  stateDir: string;
  stateFile: string;
  leaseFile: string;
  stagingDir: string;
  sourceStagingDir: string;
}

export function resolveCommandPaths(targetHome?: string): CommandPaths {
  const home = resolve(targetHome ?? process.env["HOME"] ?? ".");
  return {
    home,
    binDir: join(home, ".local/bin"),
    libDir: join(home, ".local/lib/commands"),
    storeDir: join(home, ".local/lib/commands/store"),
    currentDir: join(home, ".local/lib/commands/current"),
    quarantineDir: join(home, ".local/lib/commands/quarantine"),
    stateDir: join(home, ".local/state/chezmoi-command-reconcile"),
    stateFile: join(home, ".local/state/chezmoi-command-reconcile/state.json"),
    leaseFile: join(home, ".local/state/chezmoi-command-reconcile/lock"),
    stagingDir: join(home, ".local/share/chezmoi-commands/incomplete"),
    sourceStagingDir: join(home, ".local/share/chezmoi/command-sources"),
  };
}

export function contained(base: string, target: string): string {
  const resolvedBase = resolve(base);
  const resolvedTarget = resolve(isAbsolute(target) ? target : join(resolvedBase, target));
  const rel = relative(resolvedBase, resolvedTarget);
  if (rel.startsWith("..") || isAbsolute(rel)) {
    throw new Error(`Path escapes root containment: base=${resolvedBase} target=${resolvedTarget}`);
  }
  return resolvedTarget;
}

export async function assertExistingParentsNoSymlink(path: string, stopAt?: string): Promise<void> {
  const resolvedStop = stopAt ? resolve(stopAt) : "/";
  let current = dirname(resolve(path));
  while (current !== resolvedStop && current !== dirname(current)) {
    try {
      const st = await lstat(current);
      if (st.isSymbolicLink()) {
        throw new Error(`Symlink found in parent hierarchy: ${current}`);
      }
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
    }
    current = dirname(current);
  }
}

export async function prepareDir(path: string, mode: number): Promise<string> {
  await assertExistingParentsNoSymlink(path);
  await mkdir(path, { recursive: true, mode });
  const st = await lstat(path);
  if (!st.isDirectory() || st.isSymbolicLink()) {
    throw new Error(`Unsafe target directory: ${path}`);
  }
  return resolve(path);
}

export async function atomicSymlink(targetPath: string, linkPath: string): Promise<void> {
  const parent = dirname(linkPath);
  await prepareDir(parent, 0o755);
  const tmpLink = join(parent, `.tmp-link-${randomUUID()}`);
  try {
    await symlink(targetPath, tmpLink);
    await rename(tmpLink, linkPath);
  } catch (err) {
    await rm(tmpLink, { force: true }).catch(() => {});
    throw err;
  }
}
