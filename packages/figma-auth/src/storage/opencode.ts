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

export interface OpenCodeStorageOptions {
  path?: string;
  now?: () => number;
  beforeSourceRevalidation?: () => Promise<void>;
}

export function serverKey(serverUrl: string): string {
  const hostname = new URL(serverUrl).hostname.replace(/^www\./, "");
  const parts = hostname.split(".");
  return parts.length >= 2 ? (parts.at(-2) ?? hostname) : hostname;
}

export class OpenCodeStorage implements StorageAdapter {
  private readonly path: string;
  private readonly now: () => number;
  private readonly beforeSourceRevalidation: (() => Promise<void>) | undefined;

  constructor(options: OpenCodeStorageOptions = {}) {
    this.path = options.path ?? join(homedir(), ".local", "share", "opencode", "mcp-auth.json");
    this.now = options.now ?? Date.now;
    this.beforeSourceRevalidation = options.beforeSourceRevalidation;
  }

  async commit(session: CompletedSession): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const source = await readRegularFileIfExists(this.path);
    const key = serverKey(FIGMA_SERVER_URL);
    const stateKey = `${key.charAt(0).toUpperCase()}${key.slice(1)}`;
    const authEntry = toAuthEntry(session, this.now());
    const stateEntry = { oauthState: session.oauthState, codeVerifier: session.codeVerifier };

    let output: string;
    if (source === undefined) {
      output = `${JSON.stringify({ [key]: authEntry, [stateKey]: stateEntry }, null, 2)}\n`;
    } else {
      validateDocument(source);
      const formattingOptions = {
        insertSpaces: !source.includes("\t"),
        tabSize: 2,
        eol: source.includes("\r\n") ? "\r\n" : "\n",
      };
      output = applyEdits(source, modify(source, [key], authEntry, { formattingOptions }));
      output = applyEdits(output, modify(output, [stateKey], stateEntry, { formattingOptions }));
    }

    await atomicPrivateWrite(this.path, output, {
      beforePromote: async () => {
        await this.beforeSourceRevalidation?.();
        const current = await readRegularFileIfExists(this.path);
        if (current !== undefined) validateDocument(current);
        // WHY: OpenCode offers no cooperative lock. This catches ordinary concurrent
        // updates, but the final compare-to-rename window cannot be a kernel-level CAS.
        if (current !== source) {
          throw new Error("OpenCode auth file changed during update; refusing to overwrite it");
        }
      },
    });
  }
}

function toAuthEntry(session: CompletedSession, nowMs: number): Record<string, unknown> {
  const client = session.clientInformation;
  const tokens = session.tokens;
  return {
    serverUrl: FIGMA_SERVER_URL,
    clientInfo: {
      clientId: client.client_id,
      ...(client.client_secret === undefined ? {} : { clientSecret: client.client_secret }),
      ...(client.client_id_issued_at === undefined
        ? {}
        : { clientIdIssuedAt: client.client_id_issued_at }),
      ...(client.client_secret_expires_at === undefined
        ? {}
        : { clientSecretExpiresAt: client.client_secret_expires_at }),
    },
    tokens: {
      accessToken: tokens.access_token,
      ...(tokens.refresh_token === undefined ? {} : { refreshToken: tokens.refresh_token }),
      ...(tokens.expires_in === undefined ? {} : { expiresAt: nowMs / 1000 + tokens.expires_in }),
    },
  };
}

function validateDocument(source: string): void {
  const errors: ParseError[] = [];
  const root = parseTree(source, errors, { allowTrailingComma: false, disallowComments: false });
  if (!root || errors.length > 0) throw new Error("Existing OpenCode auth file is malformed JSON");
  if (root.type !== "object") throw new Error("Existing OpenCode auth file must contain an object");

  const seen = new Set<string>();
  for (const property of root.children ?? []) {
    const key = propertyKey(property);
    if (key === undefined) continue;
    if (seen.has(key)) throw new Error(`Existing OpenCode auth file has duplicate ${key} keys`);
    seen.add(key);
  }
}

function propertyKey(property: JsonNode): string | undefined {
  if (property.type !== "property") return undefined;
  const key = property.children?.[0];
  return key?.type === "string" && typeof key.value === "string" ? key.value : undefined;
}
