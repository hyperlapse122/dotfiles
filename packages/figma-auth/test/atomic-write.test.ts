import { chmod, lstat, mkdir, readFile, readdir, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { atomicPrivateWrite, readRegularFileIfExists } from "../src/storage/atomic.js";
import { createScratch, removeScratch } from "./helpers.js";

const scratch: string[] = [];
afterEach(async () => Promise.all(scratch.splice(0).map(removeScratch)));

async function directory(): Promise<string> {
  const path = await createScratch("atomic");
  scratch.push(path);
  return path;
}

describe("atomic private writer", () => {
  it("creates and replaces a regular 0600 file", async () => {
    const dir = await directory();
    const target = join(dir, "credentials.json");
    await atomicPrivateWrite(target, "first\n");
    await chmod(target, 0o644);
    await atomicPrivateWrite(target, "second\n");
    expect(await readFile(target, "utf8")).toBe("second\n");
    expect((await lstat(target)).mode & 0o777).toBe(0o600);
  });

  it("rejects symlink and non-regular destinations", async () => {
    const dir = await directory();
    const real = join(dir, "real");
    const link = join(dir, "link");
    await writeFile(real, "original");
    await symlink(real, link);
    await expect(atomicPrivateWrite(link, "replacement")).rejects.toThrow("symlink");
    expect(await readFile(real, "utf8")).toBe("original");

    const childDir = join(dir, "directory-target");
    await mkdir(childDir);
    await expect(atomicPrivateWrite(childDir, "replacement")).rejects.toThrow("non-regular");
  });

  it("removes a scrubbed private temporary file after a failed rename", async () => {
    const dir = await directory();
    const target = join(dir, "credentials.json");
    await expect(
      atomicPrivateWrite(target, "secret", {
        temporaryName: () => "known",
        renameFile: async () => {
          throw new Error("simulated rename failure");
        },
      }),
    ).rejects.toThrow("simulated rename failure");
    expect(await readdir(dir)).toEqual([]);
  });

  it("scrubs secrets and reports cleanup failure when a failed promotion cannot unlink", async () => {
    const dir = await directory();
    const target = join(dir, "credentials.json");
    const temporary = join(dir, ".credentials.json.known.tmp");
    await writeFile(target, "original");

    await expect(
      atomicPrivateWrite(target, "fake-secret-bytes", {
        temporaryName: () => "known",
        renameFile: async () => {
          throw new Error("simulated rename failure");
        },
        unlinkFile: async () => {
          throw new Error("simulated unlink failure");
        },
      }),
    ).rejects.toThrow(
      "simulated rename failure; temporary credential cleanup failed: simulated unlink failure",
    );

    expect(await readFile(target, "utf8")).toBe("original");
    expect(await readFile(temporary, "utf8")).toBe("");
  });

  it("reads only regular non-symlink files", async () => {
    const dir = await directory();
    const target = join(dir, "credentials.json");
    expect(await readRegularFileIfExists(target)).toBeUndefined();
    await writeFile(target, "{}\n");
    expect(await readRegularFileIfExists(target)).toBe("{}\n");

    const link = join(dir, "linked-credentials.json");
    await symlink(target, link);
    await expect(readRegularFileIfExists(link)).rejects.toThrow("symlink");

    const childDir = join(dir, "directory-target");
    await mkdir(childDir);
    await expect(readRegularFileIfExists(childDir)).rejects.toThrow("non-regular");
  });
});
