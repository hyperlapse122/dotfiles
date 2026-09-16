import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { isPayloadBody, payload, payloadPath } from "../src/payload.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "payload");

describe("payloadPath", () => {
  it("resolves under the home directory by default", () => {
    expect(payloadPath("everyone", { HOME: "/home/someone" })).toBe(
      "/home/someone/.local/share/orchestration-hook/everyone.md",
    );
    expect(payloadPath("coordinator", { HOME: "/home/someone" })).toBe(
      "/home/someone/.local/share/orchestration-hook/coordinator.md",
    );
  });

  it("falls back to the process home when HOME is empty", () => {
    expect(payloadPath("everyone", { HOME: "" })).toBe(payloadPath("everyone", {}));
    expect(payloadPath("everyone", { HOME: "" })).not.toMatch(/^\/?\.local/);
  });

  it("takes the override the tests and the CI gate set", () => {
    expect(payloadPath("everyone", { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: "/elsewhere" })).toBe(
      "/elsewhere/everyone.md",
    );
  });
});

describe("payload", () => {
  const env = { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: FIXTURES };

  it("reads the managed file verbatim", () => {
    expect(payload("everyone", env)).toBe(readFileSync(join(FIXTURES, "everyone.md"), "utf8"));
    expect(payload("coordinator", env)).toBe(
      readFileSync(join(FIXTURES, "coordinator.md"), "utf8"),
    );
  });

  it("treats a missing file as not delivered", () => {
    expect(
      payload("everyone", { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: join(FIXTURES, "nope") }),
    ).toBeNull();
  });

  it("treats an empty file as not delivered", () => {
    const dir = mkdtempSync(join(tmpdir(), "orchestration-hook-empty-"));
    try {
      writeFileSync(join(dir, "everyone.md"), "");
      expect(payload("everyone", { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: dir })).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("treats an unreadable file as not delivered rather than an error", () => {
    const dir = mkdtempSync(join(tmpdir(), "orchestration-hook-unreadable-"));
    try {
      const file = join(dir, "everyone.md");
      writeFileSync(file, "BODY\n");
      chmodSync(file, 0o000);
      // Root ignores the mode bits, so the case would assert nothing there.
      if (process.getuid?.() === 0) return;
      expect(payload("everyone", { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: dir })).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("isPayloadBody", () => {
  it("accepts the two bodies and nothing else", () => {
    expect(isPayloadBody("everyone")).toBe(true);
    expect(isPayloadBody("coordinator")).toBe(true);
    expect(isPayloadBody("nonesuch")).toBe(false);
  });
});
