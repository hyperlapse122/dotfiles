import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export interface OAuthTokens {
  access_token: string;
  refresh_token?: string | undefined;
  expires_in?: number | undefined;
  token_type?: string | undefined;
  scope?: string | undefined;
  expires_at?: number | undefined;
}

export interface ClientInformation {
  client_id: string;
  client_secret?: string | undefined;
  client_name?: string | undefined;
}

export interface StoredSession {
  tokens: OAuthTokens;
  clientInformation: ClientInformation;
  updatedAt: string;
}

export function getDefaultTokenPath(): string {
  return join(homedir(), ".local", "state", "figma-proxy", "tokens.json");
}

export class TokenStorage {
  readonly filePath: string;

  constructor(filePath: string = getDefaultTokenPath()) {
    this.filePath = filePath;
  }

  read(): StoredSession | null {
    if (!existsSync(this.filePath)) return null;
    try {
      const content = readFileSync(this.filePath, "utf-8");
      return JSON.parse(content) as StoredSession;
    } catch {
      return null;
    }
  }

  write(session: StoredSession): void {
    const dir = dirname(this.filePath);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const content = JSON.stringify(session, null, 2);
    writeFileSync(this.filePath, content, { encoding: "utf-8", mode: 0o600 });
  }

  clear(): void {
    if (existsSync(this.filePath)) {
      writeFileSync(this.filePath, "{}", { encoding: "utf-8", mode: 0o600 });
    }
  }
}
