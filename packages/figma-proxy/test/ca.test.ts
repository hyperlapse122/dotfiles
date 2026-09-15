import { existsSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vite-plus/test";
import { ensureRootCA, getHostCertificate } from "../src/ca.js";

describe("Root CA and Host Certificate Management", () => {
  let testCaDir: string;

  beforeEach(() => {
    testCaDir = join(
      tmpdir(),
      `figma-ca-test-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    );
  });

  afterEach(() => {
    try {
      rmSync(testCaDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup error
    }
  });

  it("creates Root CA certificate and private key with 0600 permissions", () => {
    const { certPath, keyPath } = ensureRootCA(testCaDir);
    expect(existsSync(certPath)).toBe(true);
    expect(existsSync(keyPath)).toBe(true);

    const keyStat = statSync(keyPath);
    // 0o600 mode (rw-------)
    expect(keyStat.mode & 0o777).toBe(0o600);
  });

  it("generates and caches host certificate signed by Root CA", () => {
    const hostname = "mcp.figma.com";
    const pair1 = getHostCertificate(hostname, testCaDir);
    expect(pair1.cert).toContain("BEGIN CERTIFICATE");
    expect(pair1.key).toContain("BEGIN PRIVATE KEY");

    const pair2 = getHostCertificate(hostname, testCaDir);
    expect(pair2).toBe(pair1); // Cached reference
  });
});
