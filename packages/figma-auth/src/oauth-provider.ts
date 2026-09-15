import type {
  OAuthClientProvider,
  OAuthDiscoveryState,
} from "@modelcontextprotocol/sdk/client/auth.js";
import type {
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";
import type { BrowserOpener } from "./browser.js";
import type { CompletedSession } from "./storage/types.js";

export const CALLBACK_PORT = 19876;
export const CALLBACK_PATH = "/callback";
export const REDIRECT_URI = `http://127.0.0.1:${CALLBACK_PORT}${CALLBACK_PATH}`;

export class FreshOAuthProvider implements OAuthClientProvider {
  readonly oauthState: string;
  private readonly opener: BrowserOpener;
  private client: OAuthClientInformationMixed | undefined;
  private tokenSet: OAuthTokens | undefined;
  private verifier: string | undefined;
  private discovery: OAuthDiscoveryState | undefined;

  constructor(oauthState: string, opener: BrowserOpener) {
    this.oauthState = oauthState;
    this.opener = opener;
  }

  get redirectUrl(): string {
    return REDIRECT_URI;
  }

  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "Codex",
      redirect_uris: [REDIRECT_URI],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    };
  }

  state(): string {
    return this.oauthState;
  }

  clientInformation(): OAuthClientInformationMixed | undefined {
    return this.client;
  }

  saveClientInformation(clientInformation: OAuthClientInformationMixed): void {
    this.client = clientInformation;
  }

  tokens(): OAuthTokens | undefined {
    return this.tokenSet;
  }

  saveTokens(tokens: OAuthTokens): void {
    this.tokenSet = tokens;
  }

  redirectToAuthorization(authorizationUrl: URL): Promise<void> {
    return this.opener(authorizationUrl);
  }

  saveCodeVerifier(codeVerifier: string): void {
    this.verifier = codeVerifier;
  }

  codeVerifier(): string {
    if (!this.verifier) throw new Error("OAuth did not provide a PKCE code verifier");
    return this.verifier;
  }

  saveDiscoveryState(discoveryState: OAuthDiscoveryState): void {
    this.discovery = discoveryState;
  }

  discoveryState(): OAuthDiscoveryState | undefined {
    return this.discovery;
  }

  invalidateCredentials(scope: "all" | "client" | "tokens" | "verifier" | "discovery"): void {
    if (scope === "all" || scope === "client") this.client = undefined;
    if (scope === "all" || scope === "tokens") this.tokenSet = undefined;
    if (scope === "all" || scope === "verifier") this.verifier = undefined;
    if (scope === "all" || scope === "discovery") this.discovery = undefined;
  }

  completedSession(): CompletedSession {
    if (!this.client) throw new Error("OAuth completed without registered client information");
    if (!this.tokenSet) throw new Error("OAuth completed without tokens");
    if (!this.verifier) throw new Error("OAuth completed without a PKCE code verifier");
    return {
      clientInformation: this.client,
      tokens: this.tokenSet,
      codeVerifier: this.verifier,
      oauthState: this.oauthState,
      ...(this.discovery === undefined ? {} : { discoveryState: this.discovery }),
    };
  }
}
