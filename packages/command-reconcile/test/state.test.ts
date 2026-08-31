import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vite-plus/test";
import { initEmptyState, readState, writeState, STATE_CONTRACT } from "../src/state.js";

describe("state", () => {
  it("initializes empty state when file does not exist", async () => {
    const testHome = join(tmpdir(), `test-state-${Date.now()}-${Math.random()}`);
    try {
      const state = await readState(testHome);
      expect(state.schemaVersion).toBe(STATE_CONTRACT);
      expect(state.revision).toBe(0);
      expect(Object.keys(state.units).length).toBe(0);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("writes and increments monotonic revision", async () => {
    const testHome = join(tmpdir(), `test-state-${Date.now()}-${Math.random()}`);
    try {
      const state = initEmptyState();
      state.units["omp"] = { activeIdentity: "v1.0.0" };
      await writeState(testHome, state);

      const loaded = await readState(testHome);
      expect(loaded.revision).toBe(1);
      expect(loaded.units["omp"]?.activeIdentity).toBe("v1.0.0");

      await writeState(testHome, loaded);
      const reloaded = await readState(testHome);
      expect(reloaded.revision).toBe(2);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("fails closed on corrupt or newer schema state", async () => {
    const testHome = join(tmpdir(), `test-state-${Date.now()}-${Math.random()}`);
    const stateDir = join(testHome, ".local/state/chezmoi-command-reconcile");
    await mkdir(stateDir, { recursive: true });
    try {
      await writeFile(join(stateDir, "state.json"), "{ invalid json", "utf-8");
      await expect(readState(testHome)).rejects.toThrow();

      await writeFile(
        join(stateDir, "state.json"),
        JSON.stringify({ schemaVersion: "command-reconcile/v999", revision: 1 }),
        "utf-8",
      );
      await expect(readState(testHome)).rejects.toThrow("Incompatible state schema");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });
});
