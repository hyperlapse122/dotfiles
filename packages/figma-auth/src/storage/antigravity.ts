import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  applyEdits,
  modify,
  parseTree,
  type Node as JsonNode,
  type ParseError,
} from "jsonc-parser";
import { atomicPrivateWrite, readRegularFileIfExists } from "./atomic.js";
import { FIGMA_SERVER_URL, type CompletedSession, type StorageAdapter } from "./types.js";

// Antigravity CLI (Google's agentic IDE) persists MCP OAuth tokens at
// ~/.gemini/antigravity-cli/mcp_oauth_tokens.json, keyed by the full server URL.
// Unlike OpenCode's derived `figma` key plus separate `Figma` state entry, every
// field Antigravity needs to refresh lives under the single URL key: the
// dynamically-registered client_id and the token set. The file is plain JSON,
// but jsonc-parser performs the same surgical, formatting-preserving merge as
// the OpenCode backend so unrelated MCP entries (and any comments a prior
// interactive login wrote) survive a credential refresh.
export interface AntigravityStorageOptions {
  path?: string;
  now?: () => number;
  beforeSourceRevalidation?: () => Promise<void>;
}

export class AntigravityStorage implements StorageAdapter {
  private readonly path: string;
  private readonly now: () => number;
  private readonly beforeSourceRevalidation: (() => Promise<void>) | undefined;

  constructor(options: AntigravityStorageOptions = {}) {
    this.path =
      options.path ?? join(homedir(), ".gemini", "antigravity-cli", "mcp_oauth_tokens.json");
    this.now = options.now ?? Date.now;
    this.beforeSourceRevalidation = options.beforeSourceRevalidation;
  }

  async commit(session: CompletedSession): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const source = await readRegularFileIfExists(this.path);
    const entry = toAntigravityEntry(session, this.now());

    let output: string;
    if (source === undefined) {
      output = `${JSON.stringify({ [FIGMA_SERVER_URL]: entry }, null, 2)}\n`;
    } else {
      validateDocument(source);
      const formattingOptions = {
        insertSpaces: !source.includes("\t"),
        tabSize: 2,
        eol: source.includes("\r\n") ? "\r\n" : "\n",
      };
      output = applyEdits(source, modify(source, [FIGMA_SERVER_URL], entry, { formattingOptions }));
    }

    await atomicPrivateWrite(this.path, output, {
      beforePromote: async () => {
        await this.beforeSourceRevalidation?.();
        const current = await readRegularFileIfExists(this.path);
        if (current !== undefined) validateDocument(current);
        // WHY: Antigravity offers no cooperative lock. This catches ordinary
        // concurrent updates, but the final compare-to-rename window cannot be a
        // kernel-level CAS.
        if (current !== source) {
          throw new Error("Antigravity auth file changed during update; refusing to overwrite it");
        }
      },
    });
  }
}

function toAntigravityEntry(session: CompletedSession, nowMs: number): Record<string, unknown> {
  const client = session.clientInformation;
  const tokens = session.tokens;
  const token: Record<string, unknown> = {
    access_token: tokens.access_token,
    // OAuth2 token_type is "bearer" for every Figma MCP issuance; default so the
    // Antigravity token object always carries the field its loader expects.
    token_type: tokens.token_type ?? "bearer",
  };
  if (tokens.refresh_token !== undefined) token.refresh_token = tokens.refresh_token;
  if (tokens.expires_in !== undefined) {
    token.expiry = new Date(nowMs + tokens.expires_in * 1000).toISOString();
  }
  return {
    client_id: client.client_id,
    // Stored for parity with the opencode/pi backends even though the
    // Antigravity CLI refresh path does not consume it; absent for the public
    // (DCR) clients this flow registers today.
    ...(client.client_secret === undefined ? {} : { client_secret: client.client_secret }),
    token,
  };
}

function validateDocument(source: string): void {
  const errors: ParseError[] = [];
  const root = parseTree(source, errors, { allowTrailingComma: false, disallowComments: false });
  if (!root || errors.length > 0) {
    throw new Error("Existing Antigravity auth file is malformed JSON");
  }
  if (root.type !== "object") {
    throw new Error("Existing Antigravity auth file must contain an object");
  }

  const seen = new Set<string>();
  for (const property of root.children ?? []) {
    const key = propertyKey(property);
    if (key === undefined) continue;
    if (seen.has(key)) throw new Error(`Existing Antigravity auth file has duplicate ${key} keys`);
    seen.add(key);
  }
}

function propertyKey(property: JsonNode): string | undefined {
  if (property.type !== "property") return undefined;
  const key = property.children?.[0];
  return key?.type === "string" && typeof key.value === "string" ? key.value : undefined;
}
