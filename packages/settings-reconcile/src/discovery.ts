import { constants } from "node:fs";
import { access, readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { isObject } from "./reconcile.js";

declare const Bun: { YAML?: { parse?: (s: string) => unknown } } | undefined;

export interface DiscoveryOptions {
  explicitPaths?: string[];
  all?: boolean;
  gardenFile?: string;
  srcDir?: string;
  worktreesDir?: string;
}

export function parseGardenYamlContent(content: string, srcRootOverride?: string): string[] {
  let parsed: unknown = null;
  if (typeof Bun !== "undefined" && Bun?.YAML?.parse && typeof Bun.YAML.parse === "function") {
    try {
      parsed = Bun.YAML.parse(content);
    } catch {
      parsed = null;
    }
  }

  const paths: string[] = [];
  const home = homedir();

  if (isObject(parsed)) {
    const rootVal = parsed.garden;
    let gardenRoot = srcRootOverride;
    if (!gardenRoot && isObject(rootVal) && typeof rootVal.root === "string") {
      const declaredRoot = rootVal.root;
      gardenRoot = isAbsolute(declaredRoot)
        ? declaredRoot
        : declaredRoot.startsWith("~/")
          ? join(home, declaredRoot.slice(2))
          : join(home, declaredRoot);
    }
    if (!gardenRoot) {
      gardenRoot = join(home, "src");
    }

    const trees = parsed.trees;
    if (isObject(trees)) {
      for (const [key, treeVal] of Object.entries(trees)) {
        if (isObject(treeVal)) {
          const treePath = treeVal.path;
          if (typeof treePath === "string" && treePath.trim()) {
            paths.push(resolve(gardenRoot, treePath.trim()));
            continue;
          }
        }
        paths.push(resolve(gardenRoot, key));
      }
      return paths;
    }
  }

  // Robust line-by-line fallback parser for environments where YAML parse fails
  let inTrees = false;
  let declaredGardenRoot = srcRootOverride || join(home, "src");

  const lines = content.split(/\r?\n/);
  for (const rawLine of lines) {
    const trimmed = rawLine.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    if (!srcRootOverride && trimmed.startsWith("root:")) {
      const val = trimmed.slice(5).trim().replace(/['"]/g, "");
      if (val) {
        declaredGardenRoot = isAbsolute(val)
          ? val
          : val.startsWith("~/")
            ? join(home, val.slice(2))
            : join(home, val);
      }
      continue;
    }

    if (rawLine.startsWith("trees:")) {
      inTrees = true;
      continue;
    }

    if (inTrees) {
      if (!rawLine.startsWith(" ") && !rawLine.startsWith("\t")) {
        inTrees = false;
        continue;
      }

      const matchPath = trimmed.match(/^path:\s*(.+)$/);
      const matchedGroup = matchPath?.[1];
      if (typeof matchedGroup === "string") {
        const val = matchedGroup.trim().replace(/['"]/g, "");
        if (val) {
          paths.push(resolve(declaredGardenRoot, val));
        }
      }
    }
  }

  return paths;
}

async function scanSrcDirFallback(srcDir: string): Promise<string[]> {
  const discovered: string[] = [];
  try {
    const hosts = await readdir(srcDir, { withFileTypes: true });
    for (const host of hosts) {
      if (!host.isDirectory() || host.name.startsWith(".")) continue;
      const hostPath = join(srcDir, host.name);
      try {
        const namespaces = await readdir(hostPath, { withFileTypes: true });
        for (const ns of namespaces) {
          if (!ns.isDirectory() || ns.name.startsWith(".")) continue;
          const nsPath = join(hostPath, ns.name);
          const hasDirectGit = await access(join(nsPath, ".git"), constants.R_OK)
            .then(() => true)
            .catch(() => false);
          if (hasDirectGit) {
            discovered.push(resolve(nsPath));
            continue;
          }
          try {
            const repos = await readdir(nsPath, { withFileTypes: true });
            for (const repo of repos) {
              if (!repo.isDirectory() || repo.name.startsWith(".")) continue;
              const repoPath = join(nsPath, repo.name);
              const hasRepoGit = await access(join(repoPath, ".git"), constants.R_OK)
                .then(() => true)
                .catch(() => false);
              if (hasRepoGit) {
                discovered.push(resolve(repoPath));
              }
            }
          } catch {
            // Ignore unreadable namespace directory
          }
        }
      } catch {
        // Ignore unreadable host directory
      }
    }
  } catch {
    // Ignore unreadable src directory
  }
  return discovered;
}

export async function discoverGardenCheckouts(
  gardenConfigFile?: string,
  srcDirOverride?: string,
): Promise<string[]> {
  const home = homedir();
  const filePath =
    gardenConfigFile ||
    process.env.GARDEN_CONFIG_FILE ||
    join(home, ".config", "garden", "garden.yaml");
  try {
    const content = await readFile(filePath, "utf8");
    const srcDir = srcDirOverride || process.env.SRC_DIR;
    return parseGardenYamlContent(content, srcDir);
  } catch {
    const isExplicitGardenFile = Boolean(gardenConfigFile || process.env.GARDEN_CONFIG_FILE);
    const hasExplicitSrcDir = Boolean(srcDirOverride || process.env.SRC_DIR);
    if (isExplicitGardenFile && !hasExplicitSrcDir) {
      return [];
    }
    const srcDir = srcDirOverride || process.env.SRC_DIR || join(home, "src");
    return scanSrcDirFallback(srcDir);
  }
}

export async function discoverWorktrees(worktreesBaseDir?: string): Promise<string[]> {
  const home = homedir();
  const baseDir =
    worktreesBaseDir || process.env.WORKTREES_DIR || join(home, ".local", "share", "worktrees");
  const discovered: string[] = [];

  try {
    const entries = await readdir(baseDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const childPath = join(baseDir, entry.name);

      const hasDirectGit = await access(join(childPath, ".git"), constants.R_OK)
        .then(() => true)
        .catch(() => false);

      if (hasDirectGit) {
        discovered.push(resolve(childPath));
        continue;
      }

      // Check one level deeper for namespaced worktrees (e.g. worktrees/dotfiles/skimmer)
      try {
        const subEntries = await readdir(childPath, { withFileTypes: true });
        for (const subEntry of subEntries) {
          if (!subEntry.isDirectory()) continue;
          const subPath = join(childPath, subEntry.name);
          const hasNestedGit = await access(join(subPath, ".git"), constants.R_OK)
            .then(() => true)
            .catch(() => false);
          if (hasNestedGit) {
            discovered.push(resolve(subPath));
          }
        }
      } catch {
        // Skip unreadable subdirectories
      }
    }
  } catch {
    return [];
  }

  return discovered;
}

export async function discoverCheckouts(options: DiscoveryOptions = {}): Promise<string[]> {
  const targetPaths: string[] = [];

  if (options.explicitPaths && options.explicitPaths.length > 0) {
    for (const p of options.explicitPaths) {
      if (typeof p === "string" && p.trim()) {
        const expanded = p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
        targetPaths.push(resolve(expanded));
      }
    }
  }

  const shouldDiscover =
    options.all || !options.explicitPaths || options.explicitPaths.length === 0;

  if (shouldDiscover) {
    const [gardenPaths, worktreePaths] = await Promise.all([
      discoverGardenCheckouts(options.gardenFile, options.srcDir),
      discoverWorktrees(options.worktreesDir),
    ]);
    targetPaths.push(...gardenPaths);
    targetPaths.push(...worktreePaths);
  }

  return Array.from(new Set(targetPaths)).sort();
}
