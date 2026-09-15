import net from "node:net";
import { afterEach, beforeEach, describe, expect, it } from "vite-plus/test";
import { FigmaProxyServer } from "../src/proxy.js";

describe("Figma Proxy Server", () => {
  let proxy: FigmaProxyServer;
  let proxyPort: number;

  beforeEach(async () => {
    // Port 0 picks random free port
    proxy = new FigmaProxyServer({ port: 0 });
    proxyPort = await proxy.start();
  });

  afterEach(async () => {
    await proxy.stop();
  });

  it("responds to /healthz with ok status", async () => {
    const res = await fetch(`http://127.0.0.1:${proxyPort}/healthz`);
    expect(res.status).toBe(200);
    const data = (await res.json()) as { status: string };
    expect(data.status).toBe("ok");
  });

  it("blind tunnels non-Figma TCP connections via HTTP CONNECT", async () => {
    // Start a dummy echo TCP server
    const echoServer = net.createServer((socket) => {
      socket.write("ECHO_HELLO");
      socket.pipe(socket);
    });

    const echoPort = await new Promise<number>((resolve) => {
      echoServer.listen(0, "127.0.0.1", () => {
        const addr = echoServer.address() as net.AddressInfo;
        resolve(addr.port);
      });
    });

    try {
      // Connect to proxy and send HTTP CONNECT to the echo server
      const client = net.connect(proxyPort, "127.0.0.1", () => {
        client.write(
          `CONNECT 127.0.0.1:${echoPort} HTTP/1.1\r\nHost: 127.0.0.1:${echoPort}\r\n\r\n`,
        );
      });

      const responseText = await new Promise<string>((resolve) => {
        let buffer = "";
        client.on("data", (chunk) => {
          buffer += chunk.toString();
          if (buffer.includes("ECHO_HELLO")) {
            client.destroy();
            resolve(buffer);
          }
        });
      });

      expect(responseText).toContain("HTTP/1.1 200 Connection Established");
      expect(responseText).toContain("ECHO_HELLO");
    } finally {
      echoServer.close();
    }
  });
});
