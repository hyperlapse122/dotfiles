import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import {
  cp,
  lstat,
  mkdir,
  open,
  readdir,
  readFile,
  realpath,
  rename,
  rm,
  stat,
} from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { parse, stringify } from "smol-toml";

export const SETTINGS_CONTRACT = "kimi-settings/v1";
export const PLUGIN_CONTRACT = "kimi-plugin/v1";

type JsonObject = Record<string, unknown>;

export interface PluginReconcileOptions {
  beforeStateWrite?: (managedRoot: string) => Promise<void>;
}

export async function reconcileSettings(
  kimiHome: string,
  file: "config.toml" | "tui.toml",
  declared: JsonObject,
): Promise<boolean> {
  const home = await prepareHome(kimiHome);
  const target = contained(home, file);
  const original = await readSafe(target);
  let current: JsonObject = {};
  if (original !== undefined) {
    const parsed = parse(original);
    if (!isObject(parsed)) throw new Error(`Kimi settings root must be a TOML table: ${target}`);
    current = parsed;
  }
  overlay(current, declared, "");
  const next = stringify(current).trimEnd() + "\n";
  if (original === next) return false;
  await atomicWrite(target, next, original);
  return true;
}

export async function reconcilePlugin(
  kimiHome: string,
  sourceRoot: string,
  release: string,
  options: PluginReconcileOptions = {},
): Promise<boolean> {
  const home = await prepareHome(kimiHome);
  const source = resolve(sourceRoot);
  await validateSourceTree(source, source);
  const manifestPath = join(source, ".kimi-plugin", "plugin.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as JsonObject;
  if (manifest.name !== "compound-engineering") {
    throw new Error("Kimi plugin manifest name must be compound-engineering");
  }
  const expectedVersion = release.replace(/^compound-engineering-v/, "");
  if (manifest.version !== undefined && manifest.version !== expectedVersion) {
    throw new Error("Kimi plugin manifest version does not match the pinned release");
  }

  const managedDir = contained(home, join("plugins", "managed"));
  await createSafeDirectoryChain(home, managedDir);
  const target = contained(home, join("plugins", "managed", "compound-engineering"));
  if (await exists(target)) {
    const targetInfo = await lstat(target);
    if (!targetInfo.isDirectory() || targetInfo.isSymbolicLink())
      throw new Error(`Unsafe managed plugin target: ${target}`);
  }
  const statePath = contained(home, join("plugins", "installed.json"));
  const stateOriginal = await readSafe(statePath);
  const state: JsonObject =
    stateOriginal === undefined ? { version: 1, plugins: [] } : JSON.parse(stateOriginal);
  if (state.version !== 1 || !Array.isArray(state.plugins)) {
    throw new Error("Unsupported Kimi plugin state; expected version 1");
  }
  await recoverPluginArtifacts(managedDir, target, state, source);
  const duplicates = state.plugins.filter(
    (entry) => isObject(entry) && entry.id === "compound-engineering",
  );
  if (duplicates.length > 1) throw new Error("Duplicate compound-engineering plugin records");
  const previous = duplicates[0];
  const now = new Date().toISOString();
  const record: JsonObject = {
    ...(isObject(previous) ? previous : {}),
    id: "compound-engineering",
    root: target,
    source: "local-path",
    originalSource: source,
    enabled: isObject(previous) && typeof previous.enabled === "boolean" ? previous.enabled : true,
    installedAt:
      isObject(previous) && typeof previous.installedAt === "string" ? previous.installedAt : now,
  };
  if (isObject(previous)) record.updatedAt = now;
  const nextPlugins = state.plugins.filter(
    (entry) => !(isObject(entry) && entry.id === "compound-engineering"),
  );
  nextPlugins.push(record);
  const nextState = JSON.stringify({ ...state, plugins: nextPlugins }, null, 2) + "\n";
  const stage = join(managedDir, `.compound-engineering.${randomUUID()}.stage`);
  const originalTargetDigest = (await exists(target)) ? await treeDigest(target) : undefined;
  let treeSame: boolean;
  let publishedDigest: string;
  try {
    await cp(source, stage, {
      recursive: true,
      errorOnExist: true,
      force: false,
      dereference: true,
    });
    publishedDigest = await treeDigest(stage);
    treeSame = originalTargetDigest !== undefined && publishedDigest === originalTargetDigest;
  } catch (error) {
    await rm(stage, { recursive: true, force: true });
    throw error;
  }
  const stateSameIgnoringUpdate =
    stateOriginal !== undefined && recordsEquivalent(stateOriginal, nextState);
  if (treeSame && stateSameIgnoringUpdate) {
    await rm(stage, { recursive: true });
    return false;
  }

  const backup = join(managedDir, `.compound-engineering.${publishedDigest}.backup`);
  let backedUp = false;
  try {
    const currentTargetDigest = (await exists(target)) ? await treeDigest(target) : undefined;
    if (currentTargetDigest !== originalTargetDigest) {
      throw new Error("Concurrent managed plugin change detected before publication");
    }
    if (originalTargetDigest !== undefined) {
      await rename(target, backup);
      backedUp = true;
    }
    await rename(stage, target);
    await options.beforeStateWrite?.(target);
    await atomicWrite(statePath, nextState, stateOriginal);
    if (backedUp) await rm(backup, { recursive: true, force: true }).catch(() => undefined);
    return true;
  } catch (error) {
    let rollbackConflict: Error | undefined;
    if (await exists(target)) {
      const currentDigest = await treeDigest(target);
      if (currentDigest === publishedDigest) await rm(target, { recursive: true });
      else
        rollbackConflict = new Error("Concurrent managed plugin change detected during rollback");
    }
    if (!rollbackConflict && backedUp && (await exists(backup))) await rename(backup, target);
    await rm(stage, { recursive: true, force: true });
    if (rollbackConflict)
      throw new AggregateError([error, rollbackConflict], rollbackConflict.message);
    throw error;
  }
}

function overlay(target: JsonObject, declared: JsonObject, prefix: string): void {
  for (const [key, value] of Object.entries(declared)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (isObject(value)) {
      const existing = target[key];
      if (existing !== undefined && !isObject(existing)) {
        throw new Error(`Managed TOML table conflicts with scalar at ${path}`);
      }
      const table = isObject(existing) ? existing : {};
      target[key] = table;
      overlay(table, value, path);
    } else {
      if (isObject(target[key]))
        throw new Error(`Managed TOML scalar conflicts with table at ${path}`);
      target[key] = value;
    }
  }
}

async function prepareHome(path: string): Promise<string> {
  if (!isAbsolute(path)) throw new Error("Kimi home must be absolute");
  await assertExistingParentsNoSymlink(path);
  await mkdir(path, { recursive: true, mode: 0o700 });
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`Unsafe Kimi home: ${path}`);
  if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
    throw new Error(`Kimi home is not owned by the current user: ${path}`);
  }
  return resolve(path);
}

function contained(home: string, suffix: string): string {
  const path = resolve(home, suffix);
  const rel = relative(home, path);
  if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel))
    throw new Error("Path escapes Kimi home");
  return path;
}

async function readSafe(path: string): Promise<string | undefined> {
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if (code(error) === "ENOENT") return undefined;
    if (code(error) === "ELOOP") throw new Error(`Refusing symlink target: ${path}`);
    throw error;
  }
  try {
    if (!(await handle.stat()).isFile()) throw new Error(`Refusing non-regular target: ${path}`);
    return await handle.readFile("utf8");
  } finally {
    await handle.close();
  }
}

async function atomicWrite(
  path: string,
  contents: string,
  expected: string | undefined,
): Promise<void> {
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`);
  const handle = await open(
    temporary,
    constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
    0o600,
  );
  try {
    await handle.writeFile(contents);
    await handle.sync();
    await handle.chmod(0o600);
  } finally {
    await handle.close();
  }
  try {
    if ((await readSafe(path)) !== expected) throw new Error(`Concurrent change detected: ${path}`);
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

async function validateTree(root: string): Promise<void> {
  const rootInfo = await lstat(root);
  if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink())
    throw new Error(`Unsafe plugin source: ${root}`);
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isSymbolicLink() || (!entry.isDirectory() && !entry.isFile()))
      throw new Error(`Unsafe plugin source entry: ${path}`);
    if (entry.isDirectory()) await validateTree(path);
  }
}

async function validateSourceTree(sourceRoot: string, directory: string): Promise<void> {
  const sourceInfo = await lstat(directory);
  if (!sourceInfo.isDirectory() || sourceInfo.isSymbolicLink())
    throw new Error(`Unsafe plugin source: ${directory}`);
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      const resolved = await realpath(path);
      const rel = relative(sourceRoot, resolved);
      if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
        throw new Error(`Plugin source symlink escapes its root: ${path}`);
      }
      const target = await stat(path);
      if (!target.isDirectory() && !target.isFile())
        throw new Error(`Unsafe plugin source entry: ${path}`);
    } else if (entry.isDirectory()) {
      await validateSourceTree(sourceRoot, path);
    } else if (!entry.isFile()) {
      throw new Error(`Unsafe plugin source entry: ${path}`);
    }
  }
}

async function recoverPluginArtifacts(
  managedDir: string,
  target: string,
  state: JsonObject,
  source: string,
): Promise<void> {
  const entries = await readdir(managedDir, { withFileTypes: true });
  const stages = entries.filter((entry) => entry.name.match(/^\.compound-engineering\..+\.stage$/));
  const backups = entries.filter((entry) =>
    entry.name.match(/^\.compound-engineering\.[0-9a-f]{64}\.backup$/),
  );
  for (const entry of [...stages, ...backups]) {
    if (!entry.isDirectory() || entry.isSymbolicLink()) {
      throw new Error(`Unsafe abandoned Kimi plugin artifact: ${join(managedDir, entry.name)}`);
    }
  }
  if (backups.length > 1)
    throw new Error("Multiple abandoned Kimi plugin backups require manual recovery");
  for (const stage of stages) await rm(join(managedDir, stage.name), { recursive: true });
  const backup = backups[0];
  if (!backup) return;
  const backupPath = join(managedDir, backup.name);
  if (!(await exists(target))) {
    await rename(backupPath, target);
    return;
  }
  const expectedPublishedDigest = backup.name.split(".")[2];
  if ((await treeDigest(target)) !== expectedPublishedDigest) {
    throw new Error("Concurrent managed plugin change detected during abandoned recovery");
  }
  const installed = Array.isArray(state.plugins)
    ? state.plugins.find((entry) => isObject(entry) && entry.id === "compound-engineering")
    : undefined;
  if (
    isObject(installed) &&
    installed.source === "local-path" &&
    installed.originalSource === source
  ) {
    await rm(backupPath, { recursive: true });
    return;
  }
  await rm(target, { recursive: true });
  await rename(backupPath, target);
}

async function treeDigest(root: string): Promise<string> {
  await validateTree(root);
  const hash = createHash("sha256");
  async function walk(dir: string): Promise<void> {
    const entries = (await readdir(dir, { withFileTypes: true })).sort((a, b) =>
      a.name.localeCompare(b.name),
    );
    for (const entry of entries) {
      const path = join(dir, entry.name);
      const rel = relative(root, path);
      hash.update(entry.isDirectory() ? `d:${rel}\0` : `f:${rel}\0`);
      if (entry.isDirectory()) await walk(path);
      else hash.update(await readFile(path));
    }
  }
  await walk(root);
  return hash.digest("hex");
}

function recordsEquivalent(oldText: string, nextText: string): boolean {
  const oldState = JSON.parse(oldText) as JsonObject;
  const nextState = JSON.parse(nextText) as JsonObject;
  const scrub = (state: JsonObject): JsonObject => ({
    ...state,
    plugins: Array.isArray(state.plugins)
      ? state.plugins.map((entry) =>
          isObject(entry) && entry.id === "compound-engineering"
            ? { ...entry, updatedAt: undefined }
            : entry,
        )
      : state.plugins,
  });
  return JSON.stringify(scrub(oldState)) === JSON.stringify(scrub(nextState));
}

async function assertExistingParentsNoSymlink(path: string): Promise<void> {
  const parts = resolve(path).split(sep).filter(Boolean);
  let current: string = sep;
  for (const part of parts) {
    current = join(current, part);
    try {
      const info = await lstat(current);
      if (info.isSymbolicLink()) throw new Error(`Refusing symlinked path component: ${current}`);
    } catch (error) {
      if (code(error) === "ENOENT") return;
      throw error;
    }
  }
}

async function createSafeDirectoryChain(home: string, path: string): Promise<void> {
  const rel = relative(home, path);
  let current = home;
  for (const part of rel.split(sep).filter(Boolean)) {
    current = join(current, part);
    try {
      await mkdir(current, { mode: 0o700 });
    } catch (error) {
      if (code(error) !== "EEXIST") throw error;
    }
    const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink())
      throw new Error(`Unsafe directory: ${current}`);
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if (code(error) === "ENOENT") return false;
    throw error;
  }
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function code(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}
