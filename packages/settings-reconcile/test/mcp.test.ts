import { describe, expect, it } from "vite-plus/test";
import { parse } from "smol-toml";
import {
  extractServers,
  formatClaudeMcp,
  formatCodexMcp,
  formatOmpMcp,
  isServerEligible,
  parseInventoryContent,
  synthesizeMcpManifest,
  validateInventory,
  validateSecretReference,
  type McpServerDeclaration,
} from "../src/mcp.js";

describe("mcp secret reference validation", () => {
  it("accepts valid 1Password secret references", () => {
    expect(validateSecretReference("op://vault/item/field")).toBe(true);
    expect(validateSecretReference("op://tum6wsa7azjvbkgwnp6fgamcvm/Context7/API Key")).toBe(true);
    expect(validateSecretReference("op://my-vault/my-item/my-section/my-field")).toBe(true);
    expect(validateSecretReference("plain-api-key-12345")).toBe(true);
  });

  it("rejects malformed 1Password secret references", () => {
    expect(() => validateSecretReference("op://")).toThrow(/Invalid 1Password secret reference/);
    expect(() => validateSecretReference("op://vault")).toThrow(/Invalid 1Password secret reference/);
    expect(() => validateSecretReference("op://vault/item")).toThrow(/Invalid 1Password secret reference/);
    expect(() => validateSecretReference("op://vault//field")).toThrow(/Invalid 1Password secret reference/);
    expect(() => validateSecretReference("op://vault/item/section/extra/field")).toThrow(
      /Invalid 1Password secret reference/,
    );
  });

  it("validates inventory declarations and identifies offending field", () => {
    const valid: McpServerDeclaration[] = [
      {
        name: "test-server",
        transport: "http",
        url: "https://example.com/mcp",
        headers: {
          API_KEY: "op://vault/item/field",
        },
      },
    ];
    expect(() => validateInventory(valid)).not.toThrow();

    const invalid: McpServerDeclaration[] = [
      {
        name: "bad-server",
        transport: "http",
        url: "https://example.com/mcp",
        headers: {
          BAD_KEY: "op://missing-segments",
        },
      },
    ];
    expect(() => validateInventory(invalid)).toThrow(
      "Invalid 1Password secret reference 'op://missing-segments' in server 'bad-server' field 'headers.BAD_KEY'",
    );
  });
});

describe("mcp server eligibility filtering", () => {
  const server: McpServerDeclaration = {
    name: "scoped-server",
    transport: "stdio",
    command: "test",
    os: ["linux"],
    container: "skip",
    harnessSkip: ["codex"],
  };

  it("filters by operating system", () => {
    expect(isServerEligible(server, { os: "linux" })).toBe(true);
    expect(isServerEligible(server, { os: "darwin" })).toBe(false);
  });

  it("filters by container status", () => {
    expect(isServerEligible(server, { os: "linux", container: false })).toBe(true);
    expect(isServerEligible(server, { os: "linux", container: true })).toBe(false);
  });

  it("filters by harness exclusion", () => {
    expect(isServerEligible(server, { os: "linux", harness: "claude" })).toBe(true);
    expect(isServerEligible(server, { os: "linux", harness: "omp" })).toBe(true);
    expect(isServerEligible(server, { os: "linux", harness: "codex" })).toBe(false);
  });
});

describe("mcp manifest formatting", () => {
  const mockInventory: McpServerDeclaration[] = [
    {
      name: "beta-stdio",
      transport: "stdio",
      command: "beta-tool",
      args: ["serve", "--flag"],
      env: {
        Z_ENV: "z-val",
        A_ENV: "a-val",
      },
    },
    {
      name: "alpha-http",
      transport: "http",
      url: "https://alpha.example.com/mcp",
      headers: {
        TOKEN: "op://vault/item/field",
      },
    },
    {
      name: "figma-oauth",
      transport: "http",
      url: "https://mcp.figma.com/mcp",
      auth: "oauth",
    },
  ];

  it("formats Claude Code JSON correctly", () => {
    const raw = formatClaudeMcp(mockInventory);
    const parsed = JSON.parse(raw);

    expect(parsed.mcpServers).toBeDefined();
    // Deterministic sorting
    const keys = Object.keys(parsed.mcpServers);
    expect(keys).toEqual(["alpha-http", "beta-stdio", "figma-oauth"]);

    // Alpha HTTP server checks
    expect(parsed.mcpServers["alpha-http"]).toEqual({
      type: "http",
      url: "https://alpha.example.com/mcp",
      headers: { TOKEN: "op://vault/item/field" },
    });

    // Beta Stdio server checks
    expect(parsed.mcpServers["beta-stdio"].command).toBe("beta-tool");
    expect(parsed.mcpServers["beta-stdio"].args).toEqual(["serve", "--flag"]);
    expect(parsed.mcpServers["beta-stdio"].env).toEqual({ A_ENV: "a-val", Z_ENV: "z-val" });
  });

  it("formats Codex TOML correctly", () => {
    const raw = formatCodexMcp(mockInventory);
    const parsed = parse(raw) as Record<string, Record<string, unknown>>;

    expect(parsed.mcp_servers).toBeDefined();
    const servers = parsed.mcp_servers;
    if (!servers) throw new Error("Expected mcp_servers to be defined");
    // Alpha HTTP: maps headers -> http_headers, omits type
    expect(servers["alpha-http"]).toEqual({
      url: "https://alpha.example.com/mcp",
      http_headers: { TOKEN: "op://vault/item/field" },
    });
    expect((servers["alpha-http"] as { type?: unknown }).type).toBeUndefined();

    // Beta stdio
    expect(servers["beta-stdio"]).toEqual({
      command: "beta-tool",
      args: ["serve", "--flag"],
      env: { A_ENV: "a-val", Z_ENV: "z-val" },
    });
  });

  it("formats oh-my-pi JSON correctly", () => {
    const raw = formatOmpMcp(mockInventory);
    const parsed = JSON.parse(raw);

    expect(parsed.$schema).toContain("mcp-schema.json");
    expect(parsed.mcpServers).toBeDefined();

    // OAuth on HTTP server mapped to auth: { type: "oauth" }
    expect(parsed.mcpServers["figma-oauth"]).toEqual({
      auth: { type: "oauth" },
      type: "http",
      url: "https://mcp.figma.com/mcp",
    });

    // Stdio server
    expect(parsed.mcpServers["beta-stdio"].command).toBe("beta-tool");
  });

  it("synthesizeMcpManifest rejects unknown harness", () => {
    expect(() => synthesizeMcpManifest("unknown" as unknown as "claude", mockInventory)).toThrow(
      "Unsupported harness 'unknown'",
    );
  });
});

describe("inventory parsing", () => {
  it("parses raw arrays and nested shapes", () => {
    const rawArray = JSON.stringify([{ name: "server-a" }]);
    expect(extractServers(parseInventoryContent(rawArray))).toEqual([{ name: "server-a" }]);

    const withServers = JSON.stringify({ servers: [{ name: "server-b" }] });
    expect(extractServers(parseInventoryContent(withServers))).toEqual([{ name: "server-b" }]);

    const withMcp = JSON.stringify({ mcp: { servers: [{ name: "server-c" }] } });
    expect(extractServers(parseInventoryContent(withMcp))).toEqual([{ name: "server-c" }]);

    const withAgents = JSON.stringify({ agents: { mcp: { servers: [{ name: "server-d" }] } } });
    expect(extractServers(parseInventoryContent(withAgents))).toEqual([{ name: "server-d" }]);
  });
});
