import { existsSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vite-plus/test";
import { TokenStorage, type StoredSession } from "../src/storage.js";

describe("Token Storage", () => {
  let testFilePath: string;

  beforeEach(() => {
    testFilePath = join(
      tmpdir(),
      `token-test-${Date.now()}-${Math.random().toString(36).slice(2)}.json`,
    );
  });

  afterEach(() => {
    try {
      rmSync(testFilePath, { force: true });
    } catch {
      // Ignore cleanup error
    }
  });

  it("returns null when token file does not exist", () => {
    const storage = new TokenStorage(testFilePath);
    expect(storage.read()).toBeNull();
  });

  it("writes session with 0600 mode and reads it back", () => {
    const storage = new TokenStorage(testFilePath);
    const session: StoredSession = {
      tokens: {
        access_token: "test-access-token",
        refresh_token: "test-refresh-token",
        expires_in: 3600,
        expires_at: Date.now() + 3600_000,
      },
      clientInformation: {
        client_id: "test-client-id",
        client_name: "TestClient",
      },
      updatedAt: new Date().toISOString(),
    };

    storage.write(session);
    expect(existsSync(testFilePath)).toBe(true);

    const stat = statSync(testFilePath);
    expect(stat.mode & 0o777).toBe(0o600);

    const readBack = storage.read();
    expect(readBack).toEqual(session);
  });
});
