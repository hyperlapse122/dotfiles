import { createHash } from "node:crypto";
import { chmod, lstat, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { atomicPrivateWrite, readRegularFileIfExists } from "./atomic.js";
import { FIGMA_SERVER_NAME, type CompletedSession, type StorageAdapter } from "./types.js";

export interface PiStorageOptions {
  authDir?: string;
  now?: () => number;
}

export function piCredentialFilename(serverName = FIGMA_SERVER_NAME): string {
  return `${createHash("sha256").update(serverName).digest("hex").slice(0, 16)}.json`;
}

export class PiStorage implements StorageAdapter {
  private readonly authDir: string;
  private readonly now: () => number;

  constructor(options: PiStorageOptions = {}) {
    this.authDir = options.authDir ?? join(homedir(), ".pi", "agent", "mcp-auth");
    this.now = options.now ?? Date.now;
  }

  async commit(session: CompletedSession): Promise<void> {
    await mkdir(this.authDir, { recursive: true, mode: 0o700 });
    const directoryStats = await lstat(this.authDir);
    if (directoryStats.isSymbolicLink() || !directoryStats.isDirectory()) {
      throw new Error(`Refusing unsafe pi auth directory: ${this.authDir}`);
    }
    if ((directoryStats.mode & 0o7777) !== 0o700) await chmod(this.authDir, 0o700);

    const path = join(this.authDir, piCredentialFilename());
    const existing = await readRegularFileIfExists(path);
    if (existing !== undefined) validateExisting(existing);

    const client = session.clientInformation;
    const tokens = session.tokens;
    const output = {
      clientInfo: {
        client_id: client.client_id,
        ...(client.client_secret === undefined ? {} : { client_secret: client.client_secret }),
        ...(client.client_id_issued_at === undefined
          ? {}
          : { client_id_issued_at: client.client_id_issued_at }),
        ...(client.client_secret_expires_at === undefined
          ? {}
          : { client_secret_expires_at: client.client_secret_expires_at }),
      },
      tokens: {
        access_token: tokens.access_token,
        ...(tokens.token_type === undefined ? {} : { token_type: tokens.token_type }),
        ...(tokens.refresh_token === undefined ? {} : { refresh_token: tokens.refresh_token }),
        ...(tokens.expires_in === undefined ? {} : { expires_in: tokens.expires_in }),
        ...(tokens.scope === undefined ? {} : { scope: tokens.scope }),
        saved_at: new Date(this.now()).toISOString(),
      },
      codeVerifier: session.codeVerifier,
      ...(session.discoveryState === undefined ? {} : { discoveryState: session.discoveryState }),
    };

    await atomicPrivateWrite(path, `${JSON.stringify(output, null, 2)}\n`);
  }
}

function validateExisting(source: string): void {
  let parsed: unknown;
  try {
    parsed = JSON.parse(source);
  } catch {
    throw new Error("Existing pi auth file is malformed JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("Existing pi auth file must contain an object");
  }
}
