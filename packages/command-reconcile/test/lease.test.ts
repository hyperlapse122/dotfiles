import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { describe, expect, it } from "vite-plus/test";
import { withLease } from "../src/lease.js";

describe("lease", () => {
  it("serializes concurrent operations", async () => {
    const testHome = join(tmpdir(), `test-lease-${Date.now()}-${Math.random()}`);
    const order: number[] = [];

    try {
      const task1 = withLease(testHome, async () => {
        order.push(1);
        await sleep(50);
        order.push(2);
        return "task1";
      });

      const task2 = withLease(testHome, async () => {
        order.push(3);
        await sleep(20);
        order.push(4);
        return "task2";
      });

      const [res1, res2] = await Promise.all([task1, task2]);
      expect(res1).toBe("task1");
      expect(res2).toBe("task2");

      const isSequential =
        (order[0] === 1 && order[1] === 2 && order[2] === 3 && order[3] === 4) ||
        (order[0] === 3 && order[1] === 4 && order[2] === 1 && order[3] === 2);
      expect(isSequential).toBe(true);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });
});
