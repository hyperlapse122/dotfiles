import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveVendorManifest, ResolutionError } from "../src/vendor-manifest.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

/** URL-prefix routed stub; an unrouted request 404s. */
function stubRoutes(routes: Record<string, () => Response>): void {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    for (const [prefix, respond] of Object.entries(routes)) {
      if (url.startsWith(prefix)) return respond();
    }
    return new Response("not stubbed", { status: 404 });
  }) as typeof globalThis.fetch;
}

function text(body: string): () => Response {
  return () => new Response(body, { status: 200 });
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

test("rejects the retired antigravity vendor as unknown", async () => {
  const spec = {
    kind: "vendorManifest",
    vendor: "antigravity",
    source: "https://agy.example.invalid/manifests",
  } as unknown as ToolSpec;

  await expect(resolveVendorManifest("agy", spec)).rejects.toThrow('unknown vendor "antigravity"');
});

describe("resolveVendorManifest winbox", () => {
  const spec: ToolSpec = {
    kind: "vendorManifest",
    vendor: "winbox",
    source: "https://download.example.invalid/routeros/winbox/LATEST.4",
  };

  test("records the bare version string, trimmed, version-only", async () => {
    stubRoutes({ "https://download.example.invalid/routeros/winbox/LATEST.4": text("4.3\n") });

    const locked = await resolveVendorManifest("winbox", spec);

    expect(locked.version).toBe("4.3");
    expect(locked.artifacts).toBeUndefined();
  });

  test("a response that is not a version fails with the source named", async () => {
    stubRoutes({
      "https://download.example.invalid/routeros/winbox/LATEST.4": text("<html>oops</html>"),
    });

    const error = await resolveVendorManifest("winbox", spec).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/download\.example\.invalid/);
  });
});
