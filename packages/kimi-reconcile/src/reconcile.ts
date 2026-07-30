import { randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, rename, rm } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { parse, stringify } from "smol-toml";

export const SETTINGS_CONTRACT = "kimi-settings/v1";

type JsonObject = Record<string, unknown>;

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

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function code(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}
