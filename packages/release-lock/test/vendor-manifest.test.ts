import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveVendorManifest, ResolutionError } from "../src/vendor-manifest.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

/**
 * URL-prefix routed stub; an unrouted request 404s. The returned array records
 * every requested URL in order, which is how the no-download property is proven:
 * a resolver that fetched an artifact body would show it here.
 */
function stubRoutes(routes: Record<string, () => Response>): string[] {
  const requests: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    requests.push(url);
    for (const [prefix, respond] of Object.entries(routes)) {
      if (url.startsWith(prefix)) return respond();
    }
    return new Response("not stubbed", { status: 404 });
  }) as typeof globalThis.fetch;
  return requests;
}

function text(body: string): () => Response {
  return () => new Response(body, { status: 200 });
}

const ONE_PASSWORD_SOURCE = "https://releases.example.invalid/linux/stable/index.xml";
const ONE_PASSWORD_FEED = `<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <item>
      <title>1Password for Linux 8.12.30</title>
      <pubDate>Mon, 10 Aug 2026 00:00:00 +0000</pubDate>
    </item>
    <item>
      <title>1Password for Linux 8.12.32</title>
      <pubDate>Tue, 11 Aug 2026 00:00:00 +0000</pubDate>
    </item>
  </channel>
</rss>`;

function onePasswordSpec(): ToolSpec {
  return {
    kind: "vendorManifest",
    vendor: "onePassword",
    source: ONE_PASSWORD_SOURCE,
  };
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

describe("resolveVendorManifest onePassword", () => {
  test("selects the newest local feed item and records only its arm64 artifact", async () => {
    const requests = stubRoutes({ [ONE_PASSWORD_SOURCE]: text(ONE_PASSWORD_FEED) });

    const locked = await resolveVendorManifest("1password", onePasswordSpec());

    expect(locked.version).toBe("8.12.32");
    expect(locked.artifacts).toEqual({
      "linux-arm64": {
        url: "https://downloads.1password.com/linux/tar/stable/aarch64/1password-8.12.32.arm64.tar.gz",
        sha256: null,
      },
    });
    expect(locked.artifacts?.["linux-arm64"]).not.toHaveProperty("emulated");
    expect(Object.keys(locked.artifacts ?? {})).toEqual(["linux-arm64"]);
    expect(requests).toEqual([ONE_PASSWORD_SOURCE]);
  });

  test("rejects a malformed title with the source named", async () => {
    stubRoutes({
      [ONE_PASSWORD_SOURCE]: text(
        ONE_PASSWORD_FEED.replace("1Password for Linux 8.12.32", "1Password Linux 8.12.32"),
      ),
    });

    const error = await resolveVendorManifest("1password", onePasswordSpec()).catch(
      (e: unknown) => e,
    );

    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(ONE_PASSWORD_SOURCE);
  });

  test("raises ResolutionError when the feed fetch fails", async () => {
    stubRoutes({ [ONE_PASSWORD_SOURCE]: () => new Response("unavailable", { status: 503 }) });

    const error = await resolveVendorManifest("1password", onePasswordSpec()).catch(
      (e: unknown) => e,
    );

    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toContain(ONE_PASSWORD_SOURCE);
  });
});
