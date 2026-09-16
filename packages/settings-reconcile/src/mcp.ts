import { stringify } from "smol-toml";

export interface McpServerDeclaration {
  name: string;
  transport?: "stdio" | "http" | "sse";
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  url?: string;
  headers?: Record<string, string>;
  auth?: string;
  os?: ("linux" | "darwin")[];
  container?: "keep" | "skip";
  harnessSkip?: string[];
  [key: string]: unknown;
}

export type HarnessKind = "claude" | "codex" | "omp";

export interface McpFilterContext {
  os?: string | undefined;
  container?: boolean | undefined;
  harness?: HarnessKind | undefined;
}

/**
 * Parses raw JSON or YAML inventory text.
 */
export function parseInventoryContent(rawContent: string): unknown {
  const trimmed = rawContent.trimStart();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    try {
      return JSON.parse(rawContent);
    } catch {
      // Fall through to YAML if JSON fails
    }
  }
  const globalObj: Record<string, unknown> = globalThis as unknown as Record<string, unknown>;
  const globalBun: unknown = "Bun" in globalObj ? globalObj.Bun : undefined;
  if (globalBun && typeof globalBun === "object" && "YAML" in globalBun) {
    const yaml = globalBun.YAML;
    if (yaml && typeof yaml === "object" && "parse" in yaml && typeof yaml.parse === "function") {
      return yaml.parse(rawContent);
    }
  }
  return JSON.parse(rawContent);
}

/**
 * Extracts the array of server declarations from parsed inventory shapes.
 */
export function extractServers(parsed: unknown): McpServerDeclaration[] {
  if (Array.isArray(parsed)) {
    return parsed as McpServerDeclaration[];
  }
  if (parsed && typeof parsed === "object") {
    if ("servers" in parsed && Array.isArray(parsed.servers)) {
      return parsed.servers as McpServerDeclaration[];
    }
    if ("mcp" in parsed && parsed.mcp && typeof parsed.mcp === "object" && "servers" in parsed.mcp && Array.isArray(parsed.mcp.servers)) {
      return parsed.mcp.servers as McpServerDeclaration[];
    }
    if ("agents" in parsed && parsed.agents && typeof parsed.agents === "object" && "mcp" in parsed.agents) {
      const mcp = parsed.agents.mcp;
      if (mcp && typeof mcp === "object" && "servers" in mcp && Array.isArray(mcp.servers)) {
        return mcp.servers as McpServerDeclaration[];
      }
    }
  }
  throw new Error(
    "Invalid MCP inventory shape: expected an array of servers, { servers: [...] }, { mcp: { servers: [...] } }, or { agents: { mcp: { servers: [...] } } }",
  );
}

/**
 * Validates a 1Password secret reference string.
 * Format: op://<vault>/<item>/<field> or op://<vault>/<item>/<section>/<field>
 * Throws an Error if the reference is malformed.
 */
export function validateSecretReference(
  ref: string,
  serverName?: string,
  fieldName?: string,
): boolean {
  if (!ref.startsWith("op://")) return true;
  const path = ref.slice("op://".length);
  const segments = path.split("/");
  if (segments.length < 3 || segments.length > 4 || segments.some((s) => s.trim().length === 0)) {
    const context = serverName && fieldName ? ` in server '${serverName}' field '${fieldName}'` : "";
    throw new Error(
      `Invalid 1Password secret reference '${ref}'${context}: expected op://<vault>/<item>[/<section>]/<field>`,
    );
  }
  return true;
}

/**
 * Validates all secret references in headers and env across an inventory of MCP servers.
 */
export function validateInventory(servers: readonly McpServerDeclaration[]): void {
  for (const server of servers) {
    if (!server.name || typeof server.name !== "string") {
      throw new Error(`Invalid MCP server declaration: missing or invalid 'name'`);
    }
    if (server.headers && typeof server.headers === "object") {
      for (const [key, value] of Object.entries(server.headers)) {
        if (typeof value === "string") {
          validateSecretReference(value, server.name, `headers.${key}`);
        }
      }
    }
    if (server.env && typeof server.env === "object") {
      for (const [key, value] of Object.entries(server.env)) {
        if (typeof value === "string") {
          validateSecretReference(value, server.name, `env.${key}`);
        }
      }
    }
  }
}

/**
 * Checks if a server declaration is eligible under the given OS, container, and harness context.
 */
export function isServerEligible(
  server: McpServerDeclaration,
  ctx: McpFilterContext,
): boolean {
  if (server.os && server.os.length > 0 && ctx.os) {
    if (!server.os.includes(ctx.os as "linux" | "darwin")) {
      return false;
    }
  }
  if (server.container === "skip" && ctx.container) {
    return false;
  }
  if (server.harnessSkip && server.harnessSkip.length > 0 && ctx.harness) {
    if (server.harnessSkip.includes(ctx.harness)) {
      return false;
    }
  }
  return true;
}

/**
 * Sorts object keys alphabetically for deterministic output.
 */
function sortObjectKeys<T extends Record<string, unknown>>(obj: T): T {
  const sorted = {} as T;
  for (const key of Object.keys(obj).sort()) {
    sorted[key as keyof T] = obj[key as keyof T];
  }
  return sorted;
}

/**
 * Compiles eligible MCP servers for Claude Code (~/.mcp.json).
 */
export function formatClaudeMcp(
  servers: readonly McpServerDeclaration[],
  ctx: McpFilterContext = { harness: "claude" },
): string {
  const mcpServers: Record<string, Record<string, unknown>> = {};
  const eligible = servers
    .filter((s) => isServerEligible(s, { ...ctx, harness: "claude" }))
    .sort((a, b) => a.name.localeCompare(b.name));

  for (const s of eligible) {
    const entry: Record<string, unknown> = {};
    if (s.transport === "stdio" || (!s.transport && s.command)) {
      entry.command = s.command;
      entry.args = s.args ?? [];
      if (s.env && Object.keys(s.env).length > 0) {
        entry.env = sortObjectKeys(s.env);
      }
    } else {
      entry.type = "http";
      entry.url = s.url;
      if (s.headers && Object.keys(s.headers).length > 0) {
        entry.headers = sortObjectKeys(s.headers);
      }
    }
    mcpServers[s.name] = entry;
  }

  return JSON.stringify({ mcpServers }, null, 2) + "\n";
}

/**
 * Compiles eligible MCP servers for oh-my-pi (~/.omp/agent/mcp.json).
 */
export function formatOmpMcp(
  servers: readonly McpServerDeclaration[],
  ctx: McpFilterContext = { harness: "omp" },
): string {
  const mcpServers: Record<string, Record<string, unknown>> = {};
  const eligible = servers
    .filter((s) => isServerEligible(s, { ...ctx, harness: "omp" }))
    .sort((a, b) => a.name.localeCompare(b.name));

  for (const s of eligible) {
    const entry: Record<string, unknown> = {};
    if (s.auth) {
      if (s.auth !== "oauth") {
        throw new Error(`omp mcp: server '${s.name}' has unknown auth '${s.auth}'; valid values: oauth`);
      }
      if (s.transport === "stdio" || (!s.transport && s.command)) {
        throw new Error(`omp mcp: stdio server '${s.name}' cannot declare auth '${s.auth}'`);
      }
      entry.auth = { type: "oauth" };
    }

    if (s.transport === "stdio" || (!s.transport && s.command)) {
      entry.command = s.command;
      entry.args = s.args ?? [];
      if (s.env && Object.keys(s.env).length > 0) {
        entry.env = sortObjectKeys(s.env);
      }
    } else {
      entry.type = "http";
      entry.url = s.url;
      if (s.headers && Object.keys(s.headers).length > 0) {
        entry.headers = sortObjectKeys(s.headers);
      }
    }
    mcpServers[s.name] = entry;
  }

  return (
    JSON.stringify(
      {
        $schema:
          "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json",
        mcpServers,
      },
      null,
      2,
    ) + "\n"
  );
}

/**
 * Compiles eligible MCP servers for Codex ([mcp_servers.<name>] in TOML).
 */
export function formatCodexMcp(
  servers: readonly McpServerDeclaration[],
  ctx: McpFilterContext = { harness: "codex" },
): string {
  const mcp_servers: Record<string, Record<string, unknown>> = {};
  const eligible = servers
    .filter((s) => isServerEligible(s, { ...ctx, harness: "codex" }))
    .sort((a, b) => a.name.localeCompare(b.name));

  for (const s of eligible) {
    const entry: Record<string, unknown> = {};
    if (s.transport === "stdio" || (!s.transport && s.command)) {
      entry.command = s.command;
      entry.args = s.args ?? [];
      if (s.env && Object.keys(s.env).length > 0) {
        entry.env = sortObjectKeys(s.env);
      }
    } else {
      entry.url = s.url;
      if (s.headers && Object.keys(s.headers).length > 0) {
        entry.http_headers = sortObjectKeys(s.headers);
      }
    }
    mcp_servers[s.name] = entry;
  }

  return stringify({ mcp_servers }).trimEnd() + "\n";
}

/**
 * Compiles MCP servers for the requested harness.
 */
export function synthesizeMcpManifest(
  harness: HarnessKind,
  servers: readonly McpServerDeclaration[],
  ctx: McpFilterContext = {},
): string {
  validateInventory(servers);
  switch (harness) {
    case "claude":
      return formatClaudeMcp(servers, ctx);
    case "omp":
      return formatOmpMcp(servers, ctx);
    case "codex":
      return formatCodexMcp(servers, ctx);
    default:
      throw new Error(`Unsupported harness '${harness}'; expected claude, codex, or omp`);
  }
}
