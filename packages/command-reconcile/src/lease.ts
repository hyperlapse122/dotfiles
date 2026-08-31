import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { prepareDir, resolveCommandPaths } from "./paths.js";

const LOCK_TIMEOUT_MS = 30000;
const LOCK_RETRY_INTERVAL_MS = 20;
const STALE_LOCK_AGE_MS = 60000;

interface LockPayload {
  pid: number;
  time: number;
}

export async function withLease<T>(
  targetHome: string | undefined,
  fn: () => Promise<T>,
): Promise<T> {
  const paths = resolveCommandPaths(targetHome);
  await prepareDir(paths.stateDir, 0o700);
  const lockDir = join(paths.stateDir, ".store.lock");
  const metaFile = join(lockDir, "info.json");

  const start = Date.now();
  let acquired = false;

  while (Date.now() - start < LOCK_TIMEOUT_MS) {
    try {
      await mkdir(lockDir, { mode: 0o700 });
      const payload: LockPayload = { pid: process.pid, time: Date.now() };
      const fd = await open(metaFile, "w", 0o600);
      await fd.writeFile(JSON.stringify(payload), "utf-8");
      await fd.sync();
      await fd.close();
      acquired = true;
      break;
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "EEXIST") {
        try {
          const raw = await readFile(metaFile, "utf-8");
          const payload = JSON.parse(raw) as LockPayload;
          const age = Date.now() - payload.time;
          let isAlive = true;
          try {
            process.kill(payload.pid, 0);
          } catch {
            isAlive = false;
          }
          if (!isAlive || age > STALE_LOCK_AGE_MS) {
            const staleTmp = join(paths.stateDir, `.stale-lock-${randomUUID()}`);
            try {
              await rename(lockDir, staleTmp);
              await rm(staleTmp, { recursive: true, force: true });
            } catch {}
            continue;
          }
        } catch {}
        await sleep(LOCK_RETRY_INTERVAL_MS);
      } else {
        throw err;
      }
    }
  }

  if (!acquired) {
    throw new Error(`Timed out waiting for store-wide lease on ${lockDir}`);
  }

  try {
    return await fn();
  } finally {
    await rm(lockDir, { recursive: true, force: true }).catch(() => {});
  }
}
