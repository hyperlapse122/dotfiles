import { afterEach, describe, expect, test } from "vite-plus/test";
import { parseLsRemoteSha, resolveGitRef, ResolutionError } from "../src/git-ref.js";
import type { ToolSpec } from "../src/types.js";

const SHA = "03369ee6d7cafbfcecc4346539b05b3dc0a603bb";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("parseLsRemoteSha", () => {
  test("extracts the 40-character commit sha from ls-remote output", () => {
    expect(parseLsRemoteSha("owner/repo", `${SHA}\trefs/heads/main\n`)).toBe(SHA);
  });

  test("unparseable output fails with the source named", () => {
    expect(() => parseLsRemoteSha("owner/repo", "")).toThrow(ResolutionError);
    expect(() => parseLsRemoteSha("owner/repo", "not-a-sha\trefs/heads/main\n")).toThrow(
      /owner\/repo/,
    );
  });
});

describe("resolveGitRef", () => {
  const spec: ToolSpec = { kind: "gitRef", source: "owner/repo", ref: "refs/heads/main" };

  test("resolves the ref through the injected exec, asserting default skillPath", async () => {
    let requestedUrl: string | undefined;
    globalThis.fetch = (async (input: string | URL | Request) => {
      requestedUrl = input instanceof Request ? input.url : String(input);
      return new Response("[]", { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof globalThis.fetch;

    const exec = async (args: readonly string[]): Promise<string> => {
      expect(args).toEqual(["ls-remote", "https://github.com/owner/repo.git", "refs/heads/main"]);
      return `${SHA}\trefs/heads/main\n`;
    };

    const locked = await resolveGitRef("tool", spec, exec);

    expect(locked.version).toBe(SHA);
    expect(locked.artifacts).toBeUndefined();
    expect(requestedUrl).toBe(
      `https://api.github.com/repos/owner/repo/contents/skills/tool?ref=${SHA}`,
    );
  });

  test("asserts declared skillPath when present in spec", async () => {
    let requestedUrl: string | undefined;
    globalThis.fetch = (async (input: string | URL | Request) => {
      requestedUrl = input instanceof Request ? input.url : String(input);
      return new Response("[]", { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof globalThis.fetch;

    const customSpec: ToolSpec = {
      kind: "gitRef",
      source: "cursor/plugins",
      ref: "refs/heads/main",
      skillPath: "pstack/skills/unslop",
    };

    const exec = async (): Promise<string> => `${SHA}\trefs/heads/main\n`;

    const locked = await resolveGitRef("unslop", customSpec, exec);

    expect(locked.version).toBe(SHA);
    expect(requestedUrl).toBe(
      `https://api.github.com/repos/cursor/plugins/contents/pstack/skills/unslop?ref=${SHA}`,
    );
  });

  test("fails with ResolutionError when skillPath 404s at the resolved sha", async () => {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ message: "Not Found" }), {
        status: 404,
        headers: { "content-type": "application/json" },
      })) as typeof globalThis.fetch;

    const exec = async (): Promise<string> => `${SHA}\trefs/heads/main\n`;

    await expect(resolveGitRef("tool", spec, exec)).rejects.toThrow(
      /owner\/repo: tool: skillPath "skills\/tool" does not exist at 03369ee6d7cafbfcecc4346539b05b3dc0a603bb/,
    );
  });

  test("fails with ResolutionError when verification returns non-200 non-404 status", async () => {
    globalThis.fetch = (async () =>
      new Response("internal error", { status: 500 })) as typeof globalThis.fetch;

    const exec = async (): Promise<string> => `${SHA}\trefs/heads/main\n`;

    await expect(resolveGitRef("tool", spec, exec)).rejects.toThrow(
      /owner\/repo: tool: verifying skillPath "skills\/tool" returned HTTP 500/,
    );
  });

  test("fails with ResolutionError when fetch throws network failure", async () => {
    globalThis.fetch = (async () => {
      throw new Error("connection reset");
    }) as typeof globalThis.fetch;

    const exec = async (): Promise<string> => `${SHA}\trefs/heads/main\n`;

    await expect(resolveGitRef("tool", spec, exec)).rejects.toThrow(
      /owner\/repo: tool: verifying skillPath "skills\/tool" failed: connection reset/,
    );
  });

  test("forwards authorization header when token is supplied", async () => {
    let authHeader: string | null = null;
    globalThis.fetch = (async (_input: string | URL | Request, init?: RequestInit) => {
      authHeader = (init?.headers as Record<string, string> | undefined)?.["authorization"] ?? null;
      return new Response("[]", { status: 200, headers: { "content-type": "application/json" } });
    }) as typeof globalThis.fetch;

    const exec = async (): Promise<string> => `${SHA}\trefs/heads/main\n`;

    await resolveGitRef("tool", spec, exec, "ghp_secret_token");

    expect(authHeader).toBe("Bearer ghp_secret_token");
  });

  test("an exec failure surfaces the source", async () => {
    const exec = async (): Promise<string> => {
      throw new Error("spawn git ENOENT");
    };

    await expect(resolveGitRef("tool", spec, exec)).rejects.toThrow(/owner\/repo/);
  });
});
