import type { OAuthDiscoveryState } from "@modelcontextprotocol/sdk/client/auth.js";
import type {
  OAuthClientInformationMixed,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";

export const FIGMA_SERVER_NAME = "figma";
export const FIGMA_SERVER_URL = "https://mcp.figma.com/mcp";

export interface CompletedSession {
  clientInformation: OAuthClientInformationMixed;
  tokens: OAuthTokens;
  codeVerifier: string;
  oauthState: string;
  discoveryState?: OAuthDiscoveryState;
}

export interface StorageAdapter {
  commit(session: CompletedSession): Promise<void>;
}
