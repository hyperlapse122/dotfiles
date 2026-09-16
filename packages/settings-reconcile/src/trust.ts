import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { discoverCheckouts, type DiscoveryOptions } from "./discovery.js";
import { atomicWrite, isObject, readSafe, reconcileSettings } from "./reconcile.js";

export interface TrustOptions extends DiscoveryOptions {
  claudeConfigFile?: string;
  codexHome?: string;
  codexConfigFile?: string;
  verbose?: boolean;
}

export interface TrustResult {
  claudeOk: boolean;
  codexOk: boolean;
  pathsCount: number;
}

export async function reconcileClaudeTrust(
  claudeJsonPath: string,
  paths: string[],
  verbose = false,
): Promise<boolean> {
  const target = resolve(claudeJsonPath);
  let original: string | undefined;
  try {
    original = await readSafe(target);
  } catch (error) {
    process.stderr.write(
      `settings-reconcile: warning: failed reading ${target}: ${error instanceof Error ? error.message : String(error)}\n`,
    );
    return false;
  }

  let data: Record<string, unknown> = {};
  if (original !== undefined && original.trim().length > 0) {
    try {
      const parsed = JSON.parse(original);
      if (!isObject(parsed)) {
        process.stderr.write(`settings-reconcile: warning: ${target} root is not an object\n`);
        return false;
      }
      data = parsed;
    } catch (error) {
      process.stderr.write(
        `settings-reconcile: warning: failed parsing ${target}: ${error instanceof Error ? error.message : String(error)}\n`,
      );
      return false;
    }
  }

  let projects: Record<string, unknown>;
  const rawProjects = data.projects;
  if (isObject(rawProjects)) {
    projects = rawProjects;
  } else {
    projects = {};
    data.projects = projects;
  }

  let changed = false;
  for (const path of paths) {
    let proj: Record<string, unknown>;
    const rawProj = projects[path];
    if (isObject(rawProj)) {
      proj = rawProj;
    } else {
      proj = {};
      projects[path] = proj;
    }

    if (proj.hasTrustDialogAccepted !== true) {
      proj.hasTrustDialogAccepted = true;
      changed = true;
    }
  }

  if (changed || original === undefined) {
    const next = JSON.stringify(data, null, 2) + "\n";
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    await atomicWrite(target, next, original);
    if (verbose) {
      process.stdout.write(`settings-reconcile: updated claude trust in ${target}\n`);
    }
  }

  return true;
}

export async function reconcileCodexTrust(
  codexHomePath: string,
  codexConfigPath: string,
  paths: string[],
  verbose = false,
): Promise<boolean> {
  const codexHome = resolve(codexHomePath);
  const targetConfig = resolve(codexConfigPath);
  const fileName = basename(targetConfig);

  if (fileName !== "config.toml" && fileName !== "tui.toml") {
    process.stderr.write(`settings-reconcile: invalid codex config filename: ${fileName}\n`);
    return false;
  }

  const projectsOverlay: Record<string, unknown> = {};
  for (const p of paths) {
    projectsOverlay[p] = { trust_level: "trusted" };
  }

  const declared: Record<string, unknown> = {
    projects: projectsOverlay,
  };

  try {
    const changed = await reconcileSettings(codexHome, fileName, declared);
    if (verbose && changed) {
      process.stdout.write(`settings-reconcile: updated codex trust in ${targetConfig}\n`);
    }
    return true;
  } catch (error) {
    process.stderr.write(
      `settings-reconcile: failed reconciling codex trust: ${error instanceof Error ? error.message : String(error)}\n`,
    );
    return false;
  }
}

export async function reconcileTrust(options: TrustOptions = {}): Promise<TrustResult> {
  const home = homedir();
  const claudeConfig =
    options.claudeConfigFile || process.env.CLAUDE_CONFIG_FILE || join(home, ".claude.json");
  const codexHome = options.codexHome || process.env.CODEX_HOME || join(home, ".codex");
  const codexConfig =
    options.codexConfigFile || process.env.CODEX_CONFIG_FILE || join(codexHome, "config.toml");

  const paths = await discoverCheckouts(options);
  if (paths.length === 0) {
    if (options.verbose) {
      process.stdout.write("settings-reconcile: no checkouts found or specified.\n");
    }
    return { claudeOk: true, codexOk: true, pathsCount: 0 };
  }

  const claudeOk = await reconcileClaudeTrust(claudeConfig, paths, options.verbose);
  const codexOk = await reconcileCodexTrust(codexHome, codexConfig, paths, options.verbose);

  if (options.verbose) {
    process.stdout.write(`settings-reconcile: reconciled trust for ${paths.length} path(s)\n`);
  }

  return { claudeOk, codexOk, pathsCount: paths.length };
}
