import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveNpmPackage, ResolutionError } from "../src/npm.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

const SPEC: ToolSpec = { kind: "npm", source: "@scope/tool" };

function stubRegistry(body: unknown, status = 200): void {
  globalThis.fetch = (async () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })) as typeof globalThis.fetch;
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("resolveNpmPackage", () => {
  test("records the version and the dist.integrity digest as published", async () => {
    stubRegistry({ version: "1.0.10", dist: { integrity: "sha512-abc123==" } });

    const locked = await resolveNpmPackage("tool", SPEC);

    expect(locked.version).toBe("1.0.10");
    expect(locked.integrity).toBe("sha512-abc123==");
    expect(locked.artifacts).toBeUndefined();
  });

  test("a package without dist.integrity records a null integrity", async () => {
    stubRegistry({ version: "0.1.0", dist: {} });

    const locked = await resolveNpmPackage("tool", SPEC);

    expect(locked.version).toBe("0.1.0");
    expect(locked.integrity).toBeNull();
  });

  test("a response without a version fails with the source named", async () => {
    stubRegistry({ dist: {} });

    await expect(resolveNpmPackage("tool", SPEC)).rejects.toThrow(/@scope\/tool/);
  });

  test("a 404 fails with the source named", async () => {
    stubRegistry("not found", 404);

    const error = await resolveNpmPackage("tool", SPEC).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/@scope\/tool/);
  });
});
