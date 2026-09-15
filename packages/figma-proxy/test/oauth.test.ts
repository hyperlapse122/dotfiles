import { rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vite-plus/test";
import { generatePkce, OAuthManager } from "../src/oauth.js";
import { TokenStorage } from "../src/storage.js";

describe("OAuth Manager & PKCE", () => {
  let testFilePath: string;

  beforeEach(() => {
    testFilePath = join(
      tmpdir(),
      `oauth-test-${Date.now()}-${Math.random().toString(36).slice(2)}.json`,
    );
  });

  afterEach(() => {
    try {
      rmSync(testFilePath, { force: true });
    } catch {
      // Ignore
    }
  });

  it("generates valid PKCE verifier and challenge", () => {
    const pkce = generatePkce();
    expect(pkce.verifier).toBeTruthy();
    expect(pkce.challenge).toBeTruthy();
    expect(pkce.verifier.length).toBeGreaterThanOrEqual(43);
  });

  it("returns unexpired token from storage", async () => {
    const storage = new TokenStorage(testFilePath);
    storage.write({
      tokens: {
        access_token: "active-token",
        expires_at: Date.now() + 100_000,
      },
      clientInformation: { client_id: "id" },
      updatedAt: new Date().toISOString(),
    });

    const manager = new OAuthManager(storage);
    const token = await manager.getValidToken();
    expect(token).toBe("active-token");
  });

  it("returns null when no session exists", async () => {
    const storage = new TokenStorage(testFilePath);
    const manager = new OAuthManager(storage);
    const token = await manager.getValidToken();
    expect(token).toBeNull();
  });
});
