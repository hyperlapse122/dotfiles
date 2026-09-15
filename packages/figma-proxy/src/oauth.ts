import { createHash, randomBytes } from "node:crypto";
import { openBrowser, type BrowserOpener } from "./browser.js";
import { REDIRECT_URI, startCallbackServer, type CallbackServer } from "./callback-server.js";
import {
  TokenStorage,
  type ClientInformation,
  type OAuthTokens,
  type StoredSession,
} from "./storage.js";

export const FIGMA_AUTH_URL = "https://www.figma.com/oauth/mcp";
export const FIGMA_TOKEN_URL = "https://api.figma.com/v1/oauth/token";
export const FIGMA_REGISTER_URL = "https://api.figma.com/v1/oauth/mcp/register";

export interface PkcePair {
  verifier: string;
  challenge: string;
}

export function generatePkce(): PkcePair {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

export async function registerClient(): Promise<ClientInformation> {
  const response = await fetch(FIGMA_REGISTER_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_name: "Codex",
      redirect_uris: [REDIRECT_URI],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Failed to register OAuth client with Figma: ${response.status} ${errorText}`);
  }

  const data = (await response.json()) as { client_id: string; client_secret?: string };
  return {
    client_id: data.client_id,
    client_secret: data.client_secret,
    client_name: "Codex",
  };
}

export class OAuthManager {
  readonly storage: TokenStorage;
  readonly opener: BrowserOpener;

  constructor(storage: TokenStorage = new TokenStorage(), opener: BrowserOpener = openBrowser) {
    this.storage = storage;
    this.opener = opener;
  }

  async getValidToken(): Promise<string | null> {
    const session = this.storage.read();
    if (!session || !session.tokens?.access_token) return null;

    const now = Date.now();
    const expiresAt = session.tokens.expires_at ?? 0;

    // If token is still valid with a 60s buffer, return it
    if (expiresAt > now + 60_000) {
      return session.tokens.access_token;
    }

    // Try refresh if refresh_token is present
    if (session.tokens.refresh_token && session.clientInformation?.client_id) {
      try {
        const refreshed = await this.refreshToken(session);
        return refreshed.access_token;
      } catch {
        // If refresh fails, token is invalid
        return null;
      }
    }

    return null;
  }

  async refreshToken(session: StoredSession): Promise<OAuthTokens> {
    const { client_id } = session.clientInformation;
    const { refresh_token } = session.tokens;
    if (!refresh_token) throw new Error("No refresh token available");

    const bodyParams = new URLSearchParams({
      client_id,
      grant_type: "refresh_token",
      refresh_token,
    });

    const response = await fetch(FIGMA_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: bodyParams.toString(),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token refresh failed: ${response.status} ${errorText}`);
    }

    const data = (await response.json()) as {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
      token_type?: string;
      scope?: string;
    };

    const tokens: OAuthTokens = {
      access_token: data.access_token,
      refresh_token: data.refresh_token ?? refresh_token,
      expires_in: data.expires_in,
      token_type: data.token_type,
      scope: data.scope,
      expires_at: data.expires_in ? Date.now() + data.expires_in * 1000 : undefined,
    };

    this.storage.write({
      ...session,
      tokens,
      updatedAt: new Date().toISOString(),
    });

    return tokens;
  }

  async login(signal?: AbortSignal): Promise<StoredSession> {
    signal?.throwIfAborted();

    let session = this.storage.read();
    let clientInfo = session?.clientInformation;
    if (!clientInfo?.client_id) {
      clientInfo = await registerClient();
    }

    const pkce = generatePkce();
    const state = randomBytes(32).toString("base64url");

    let callbackServer: CallbackServer | undefined;
    try {
      callbackServer = await startCallbackServer({ state, signal });
      const waitForCode = callbackServer.waitForCode();

      const authUrl = new URL(FIGMA_AUTH_URL);
      authUrl.searchParams.set("client_id", clientInfo.client_id);
      authUrl.searchParams.set("redirect_uri", REDIRECT_URI);
      authUrl.searchParams.set("response_type", "code");
      authUrl.searchParams.set("scope", "mcp:connect");
      authUrl.searchParams.set("state", state);
      authUrl.searchParams.set("code_challenge", pkce.challenge);
      authUrl.searchParams.set("code_challenge_method", "S256");

      await this.opener(authUrl);

      const code = await waitForCode;

      const tokenParams = new URLSearchParams({
        client_id: clientInfo.client_id,
        grant_type: "authorization_code",
        code,
        code_verifier: pkce.verifier,
        redirect_uri: REDIRECT_URI,
      });

      const tokenRes = await fetch(FIGMA_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: tokenParams.toString(),
      });

      if (!tokenRes.ok) {
        const errorText = await tokenRes.text();
        throw new Error(`OAuth token exchange failed: ${tokenRes.status} ${errorText}`);
      }

      const tokenData = (await tokenRes.json()) as {
        access_token: string;
        refresh_token?: string;
        expires_in?: number;
        token_type?: string;
        scope?: string;
      };

      const tokens: OAuthTokens = {
        access_token: tokenData.access_token,
        refresh_token: tokenData.refresh_token,
        expires_in: tokenData.expires_in,
        token_type: tokenData.token_type,
        scope: tokenData.scope,
        expires_at: tokenData.expires_in ? Date.now() + tokenData.expires_in * 1000 : undefined,
      };

      const newSession: StoredSession = {
        tokens,
        clientInformation: clientInfo,
        updatedAt: new Date().toISOString(),
      };

      this.storage.write(newSession);
      return newSession;
    } finally {
      if (callbackServer) {
        await callbackServer.close().catch(() => undefined);
      }
    }
  }
}
