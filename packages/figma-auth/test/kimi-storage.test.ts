import { chmod, lstat, mkdir, readFile, readdir, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { KIMI_FIGMA_STORE_KEY, KimiStorage } from "../src/storage/kimi.js";
import type { CompletedSession } from "../src/storage/types.js";
import { createScratch, removeScratch } from "./helpers.js";

const scratch: string[] = [];
afterEach(async () => Promise.all(scratch.splice(0).map(removeScratch)));

function session(suffix = "one", discovery = true): CompletedSession {
  return {
    clientInformation: {
      client_id: `fake-client-${suffix}`,
      client_secret: `fake-client-secret-${suffix}`,
      redirect_uris: ["http://127.0.0.1:3118/callback"],
    },
    tokens: {
      access_token: `fake-access-${suffix}`,
      token_type: "bearer",
      refresh_token: `fake-refresh-${suffix}`,
      expires_in: 3600,
    },
    codeVerifier: `fake-verifier-${suffix}`,
    oauthState: `fake-state-${suffix}`,
    ...(discovery
      ? {
          discoveryState: {
            authorizationServerUrl: "https://www.figma.com/oauth",
          },
        }
      : {}),
  };
}

async function kimiHome(): Promise<string> {
  const home = await createScratch("kimi");
  scratch.push(home);
  return home;
}

function credentialPath(home: string, suffix: "client" | "tokens" | "discovery"): string {
  return join(home, "credentials", "mcp", `${KIMI_FIGMA_STORE_KEY}-${suffix}.json`);
}

describe("Kimi storage", () => {
  it("writes Kimi's exact native credential documents privately", async () => {
    const home = await kimiHome();
    await new KimiStorage({ home }).commit(session());

    expect(KIMI_FIGMA_STORE_KEY).toBe("figma-16c8c86ce11b09357be35b5b");
    expect(JSON.parse(await readFile(credentialPath(home, "client"), "utf8"))).toEqual(
      session().clientInformation,
    );
    expect(JSON.parse(await readFile(credentialPath(home, "tokens"), "utf8"))).toEqual(
      session().tokens,
    );
    expect(JSON.parse(await readFile(credentialPath(home, "discovery"), "utf8"))).toEqual(
      session().discoveryState,
    );
    expect((await lstat(join(home, "credentials"))).mode & 0o777).toBe(0o700);
    expect((await lstat(join(home, "credentials", "mcp"))).mode & 0o777).toBe(0o700);
    expect((await lstat(credentialPath(home, "tokens"))).mode & 0o777).toBe(0o600);
  });

  it("preserves discovery when a fresh session does not supply it", async () => {
    const home = await kimiHome();
    const storage = new KimiStorage({ home });
    await storage.commit(session("old"));
    const discovery = await readFile(credentialPath(home, "discovery"), "utf8");

    await storage.commit(session("new", false));

    expect(await readFile(credentialPath(home, "discovery"), "utf8")).toBe(discovery);
    expect(await readFile(credentialPath(home, "tokens"), "utf8")).toContain("fake-access-new");
  });

  it("honors KIMI_CODE_HOME and repairs private directory modes", async () => {
    const home = await kimiHome();
    await mkdir(join(home, "credentials", "mcp"), { recursive: true });
    await chmod(join(home, "credentials"), 0o755);
    await chmod(join(home, "credentials", "mcp"), 0o755);
    const previous = process.env.KIMI_CODE_HOME;
    process.env.KIMI_CODE_HOME = home;
    try {
      await new KimiStorage().commit(session());
    } finally {
      if (previous === undefined) delete process.env.KIMI_CODE_HOME;
      else process.env.KIMI_CODE_HOME = previous;
    }
    expect((await lstat(join(home, "credentials"))).mode & 0o777).toBe(0o700);
    expect((await lstat(join(home, "credentials", "mcp"))).mode & 0o777).toBe(0o700);
    expect(await readFile(credentialPath(home, "client"), "utf8")).toContain("fake-client-one");
  });

  it("restores the complete old generation when promotion fails", async () => {
    const home = await kimiHome();
    await new KimiStorage({ home }).commit(session("old"));
    let promoted = 0;
    const storage = new KimiStorage({
      home,
      afterPromote: async () => {
        promoted += 1;
        if (promoted === 2) throw new Error("injected promotion failure");
      },
    });

    await expect(storage.commit(session("new"))).rejects.toThrow("credential transaction failed");
    expect(await readFile(credentialPath(home, "client"), "utf8")).toContain("fake-client-old");
    expect(await readFile(credentialPath(home, "tokens"), "utf8")).toContain("fake-access-old");
    expect(await readFile(credentialPath(home, "discovery"), "utf8")).toContain(
      "authorizationServerUrl",
    );
  });

  it("does not overwrite a concurrent update to an unpromoted file during rollback", async () => {
    const home = await kimiHome();
    await new KimiStorage({ home }).commit(session("old"));
    const tokens = credentialPath(home, "tokens");
    const concurrent = '{"access_token":"concurrent","token_type":"bearer"}\n';
    const storage = new KimiStorage({
      home,
      afterPromote: async (_path, index) => {
        if (index === 1) {
          await writeFile(tokens, concurrent);
          throw new Error("injected failure after client promotion");
        }
      },
    });

    await expect(storage.commit(session("new"))).rejects.toThrow("credential transaction failed");
    expect(await readFile(credentialPath(home, "client"), "utf8")).toContain("fake-client-old");
    expect(await readFile(tokens, "utf8")).toBe(concurrent);
  });

  it("preserves a concurrent update to a promoted file and retains recovery state", async () => {
    const home = await kimiHome();
    await new KimiStorage({ home }).commit(session("old"));
    const client = credentialPath(home, "client");
    const concurrent = '{"client_id":"concurrent"}\n';
    const storage = new KimiStorage({
      home,
      afterPromote: async (_path, index) => {
        if (index === 1) {
          await writeFile(client, concurrent);
          throw new Error("injected failure after concurrent client update");
        }
      },
    });

    await expect(storage.commit(session("new"))).rejects.toThrow("rollback was incomplete");
    expect(await readFile(client, "utf8")).toBe(concurrent);
    expect(await readdir(join(home, "credentials", "mcp"))).toContain(
      `.${KIMI_FIGMA_STORE_KEY}-transaction.json`,
    );
    await expect(new KimiStorage({ home }).commit(session("later"))).rejects.toThrow(
      "recovery found a concurrent update",
    );
  });

  it("rejects an owned symlink and a symlinked credential parent", async () => {
    const home = await kimiHome();
    const dir = join(home, "credentials", "mcp");
    await mkdir(dir, { recursive: true });
    const real = join(home, "real.json");
    await writeFile(real, '{"keep":true}\n');
    await symlink(real, credentialPath(home, "client"));
    await expect(new KimiStorage({ home }).commit(session())).rejects.toThrow("symlink");
    expect(await readFile(real, "utf8")).toBe('{"keep":true}\n');

    const otherHome = await kimiHome();
    const external = join(otherHome, "external");
    await mkdir(external);
    await symlink(external, join(otherHome, "credentials"));
    await expect(new KimiStorage({ home: otherHome }).commit(session())).rejects.toThrow("symlink");
  });

  it("rejects a symlinked ancestor above KIMI_CODE_HOME", async () => {
    const root = await kimiHome();
    const realParent = join(root, "real-parent");
    const linkedParent = join(root, "linked-parent");
    await mkdir(realParent);
    await symlink(realParent, linkedParent);

    await expect(
      new KimiStorage({ home: join(linkedParent, "kimi-home") }).commit(session()),
    ).rejects.toThrow("symlink credential directory ancestor");
  });

  it.each([
    ["malformed", "{not json", "malformed"],
    ["array", "[]\n", "malformed"],
  ])("rejects a %s owned document without mutation", async (_name, source, message) => {
    const home = await kimiHome();
    const path = credentialPath(home, "tokens");
    await mkdir(join(path, ".."), { recursive: true });
    await writeFile(path, source);
    await expect(new KimiStorage({ home }).commit(session())).rejects.toThrow(message);
    expect(await readFile(path, "utf8")).toBe(source);
  });

  it("preserves a concurrent owned-file update", async () => {
    const home = await kimiHome();
    await new KimiStorage({ home }).commit(session("old"));
    const tokens = credentialPath(home, "tokens");
    const concurrent = '{"access_token":"concurrent","token_type":"bearer"}\n';
    const storage = new KimiStorage({
      home,
      beforeSourceRevalidation: async () => writeFile(tokens, concurrent),
    });

    await expect(storage.commit(session("new"))).rejects.toThrow("changed during update");
    expect(await readFile(tokens, "utf8")).toBe(concurrent);
  });
});
