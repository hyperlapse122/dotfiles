import http from "node:http";
import https from "node:https";
import net from "node:net";
import type stream from "node:stream";
import tls from "node:tls";
import { getHostCertificate } from "./ca.js";
import { OAuthManager } from "./oauth.js";

export interface ProxyOptions {
  port?: number | undefined;
  caDir?: string | undefined;
  oauthManager?: OAuthManager | undefined;
}

export const TARGET_HOST = "mcp.figma.com";

export class FigmaProxyServer {
  readonly port: number;
  readonly caDir?: string | undefined;
  readonly oauthManager: OAuthManager;
  private server?: http.Server | undefined;
  private directHttpsAgent: https.Agent;

  constructor(options: ProxyOptions = {}) {
    this.port =
      options.port ?? (process.env.FIGMA_PROXY_PORT ? Number(process.env.FIGMA_PROXY_PORT) : 8888);
    this.caDir = options.caDir;
    this.oauthManager = options.oauthManager ?? new OAuthManager();
    // Dedicated agent for direct outbound connections, ensuring no proxy loopback
    this.directHttpsAgent = new https.Agent({ keepAlive: true });
  }

  async start(): Promise<number> {
    return new Promise((resolve, reject) => {
      const server = http.createServer((req, res) => {
        if (req.url === "/healthz" || req.url === "/status") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ status: "ok", port: this.port }));
          return;
        }
        res.writeHead(400, { "Content-Type": "text/plain" });
        res.end("Figma Proxy: Use HTTP CONNECT for HTTPS proxying.\n");
      });

      server.on("connect", (req, clientSocket, head) => {
        this.handleConnect(req, clientSocket, head);
      });

      server.once("error", reject);
      server.listen(this.port, "127.0.0.1", () => {
        server.off("error", reject);
        this.server = server;
        const addr = server.address();
        const actualPort = typeof addr === "object" && addr ? addr.port : this.port;
        resolve(actualPort);
      });
    });
  }

  async stop(): Promise<void> {
    this.directHttpsAgent.destroy();
    if (this.server) {
      await new Promise<void>((resolve, reject) => {
        this.server?.close((err) => (err ? reject(err) : resolve()));
      });
      this.server = undefined;
    }
  }

  private handleConnect(
    req: http.IncomingMessage,
    clientSocket: stream.Duplex,
    head: Buffer,
  ): void {
    const url = req.url || "";
    const [targetHost, targetPortStr] = url.split(":");
    const targetPort = targetPortStr ? Number(targetPortStr) : 443;

    if (!targetHost) {
      clientSocket.destroy();
      return;
    }

    if (targetHost !== TARGET_HOST) {
      // Blind TCP tunnel for non-Figma destinations (R4)
      const upstreamSocket = net.connect(targetPort, targetHost, () => {
        clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        if (head && head.length > 0) {
          upstreamSocket.write(head);
        }
        upstreamSocket.pipe(clientSocket);
        clientSocket.pipe(upstreamSocket);
      });

      upstreamSocket.on("error", () => clientSocket.destroy());
      clientSocket.on("error", () => upstreamSocket.destroy());
      return;
    }

    // MITM Interception for mcp.figma.com:443 (R5)
    clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");

    const { key, cert } = getHostCertificate(TARGET_HOST, this.caDir);
    const secureContext = tls.createSecureContext({ key, cert });

    const tlsSocket = new tls.TLSSocket(clientSocket, {
      isServer: true,
      secureContext,
    });

    const internalHttpServer = http.createServer((innerReq, innerRes) => {
      void this.handleMcpRequest(innerReq, innerRes);
    });

    tlsSocket.on("error", () => {
      clientSocket.destroy();
    });

    // When TLS handshake completes, pass to internal HTTP server
    tlsSocket.on("secure", () => {
      if (head && head.length > 0) {
        tlsSocket.unshift(head);
      }
      internalHttpServer.emit("connection", tlsSocket);
    });
  }

  private async handleMcpRequest(
    req: http.IncomingMessage,
    res: http.ServerResponse,
  ): Promise<void> {
    try {
      const outboundHeaders = { ...req.headers };
      // Delete hop-by-hop headers
      delete outboundHeaders.connection;
      delete outboundHeaders["proxy-connection"];
      delete outboundHeaders["keep-alive"];
      delete outboundHeaders.host;
      outboundHeaders.host = TARGET_HOST;

      // Check Authorization header
      if (!outboundHeaders.authorization) {
        let token = await this.oauthManager.getValidToken();
        if (!token) {
          // Trigger browser flow on demand if no token exists (R9)
          const session = await this.oauthManager.login();
          token = session.tokens.access_token;
        }
        outboundHeaders.authorization = `Bearer ${token}`;
      }

      const upstreamReq = https.request(
        {
          hostname: TARGET_HOST,
          port: 443,
          path: req.url,
          method: req.method,
          headers: outboundHeaders,
          agent: this.directHttpsAgent,
        },
        (upstreamRes) => {
          res.writeHead(upstreamRes.statusCode || 200, upstreamRes.headers);
          upstreamRes.pipe(res);
        },
      );

      upstreamReq.on("error", (err) => {
        if (!res.headersSent) {
          res.writeHead(502, { "Content-Type": "text/plain" });
          res.end(`Figma Proxy Gateway Error: ${err.message}\n`);
        }
      });

      req.pipe(upstreamReq);
    } catch (error) {
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end(
          `Figma Proxy Internal Error: ${error instanceof Error ? error.message : String(error)}\n`,
        );
      }
    }
  }
}
