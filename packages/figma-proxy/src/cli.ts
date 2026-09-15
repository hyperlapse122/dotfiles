import { ensureRootCA, getDefaultCADir } from "./ca.js";
import { OAuthManager } from "./oauth.js";
import { FigmaProxyServer } from "./proxy.js";
import { TokenStorage } from "./storage.js";

export interface CliDependencies {
  stdout?: { write(value: string): unknown };
  stderr?: { write(value: string): unknown };
  storage?: TokenStorage;
  oauthManager?: OAuthManager;
}

export const USAGE = `Usage: figma-proxy <command>

Commands:
  start       Start the Figma forward proxy daemon
  login       Perform interactive OAuth browser login
  status      Show current OAuth token and proxy status
  ca-init     Generate or inspect local Root CA certificate
`;

export async function runCli(args: string[], deps: CliDependencies = {}): Promise<number> {
  const stdout = deps.stdout ?? process.stdout;
  const stderr = deps.stderr ?? process.stderr;
  const storage = deps.storage ?? new TokenStorage();
  const oauthManager = deps.oauthManager ?? new OAuthManager(storage);

  const command = args[0];

  if (!command || command === "--help" || command === "-h") {
    stdout.write(USAGE);
    return command ? 0 : 2;
  }

  switch (command) {
    case "start": {
      const port = process.env.FIGMA_PROXY_PORT ? Number(process.env.FIGMA_PROXY_PORT) : 8888;
      const server = new FigmaProxyServer({ port, oauthManager });
      ensureRootCA();
      const boundPort = await server.start();
      stdout.write(`Figma MCP Proxy running on 127.0.0.1:${boundPort}\n`);

      const shutdown = async (): Promise<void> => {
        await server.stop();
        process.exit(0);
      };

      process.on("SIGINT", () => void shutdown());
      process.on("SIGTERM", () => void shutdown());

      // Keep running
      await new Promise<void>(() => undefined);
      return 0;
    }

    case "login": {
      stdout.write("Opening browser for Figma OAuth authorization...\n");
      try {
        const session = await oauthManager.login();
        stdout.write(
          `Figma MCP authorization successful. Tokens saved (expires in ${session.tokens.expires_in ?? 0}s).\n`,
        );
        return 0;
      } catch (error) {
        stderr.write(`Login failed: ${error instanceof Error ? error.message : String(error)}\n`);
        return 1;
      }
    }

    case "status": {
      const session = storage.read();
      stdout.write("--- Figma MCP Proxy Status ---\n");
      const caDir = getDefaultCADir();
      stdout.write(`CA Directory: ${caDir}\n`);
      stdout.write(`Token Storage: ${storage.filePath}\n`);

      if (!session || !session.tokens?.access_token) {
        stdout.write("OAuth Token: Not authenticated. Run 'figma-proxy login' to authorize.\n");
        return 0;
      }

      const expiresAt = session.tokens.expires_at ?? 0;
      const now = Date.now();
      const remainingSec = Math.max(0, Math.floor((expiresAt - now) / 1000));

      if (remainingSec > 0) {
        stdout.write(`OAuth Token: Valid (expires in ${remainingSec}s)\n`);
      } else if (session.tokens.refresh_token) {
        stdout.write(
          "OAuth Token: Access token expired, but refresh token is available (auto-refresh on next request)\n",
        );
      } else {
        stdout.write(
          "OAuth Token: Expired and no refresh token available. Re-run 'figma-proxy login'.\n",
        );
      }

      stdout.write(`Client ID: ${session.clientInformation?.client_id ?? "unknown"}\n`);
      stdout.write(`Last Updated: ${session.updatedAt}\n`);
      return 0;
    }

    case "ca-init": {
      const { certPath, keyPath } = ensureRootCA();
      stdout.write(`Root CA Certificate: ${certPath}\n`);
      stdout.write(`Root CA Private Key:  ${keyPath}\n`);
      stdout.write(
        "Run 'sudo update-ca-trust' or install to system trust store to trust this CA.\n",
      );
      return 0;
    }

    default: {
      stderr.write(`Unknown command: ${command}\n\n${USAGE}`);
      return 2;
    }
  }
}
