import { describe, expect, it } from "vite-plus/test";
import {
  createProxyHandler,
  DEFAULT_UPSTREAM_ORIGIN,
  type FetchLike,
  rewriteSystemInstructionParts,
} from "../src/proxy.js";
import { listenSidecar } from "../src/server.js";

const STREAM_PATH = "/v1internal:streamGenerateContent";

function jsonRequest(path: string, body: unknown, init: RequestInit = {}): Request {
  const headers = new Headers(init.headers);
  if (!headers.has("content-type")) headers.set("content-type", "application/json");
  return new Request(`http://127.0.0.1${path}`, {
    ...init,
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

async function forwardedRequest(
  input: RequestInfo | URL,
  init: RequestInit | undefined,
): Promise<Request> {
  return new Request(input, init);
}

describe("system instruction rewriting", () => {
  it("rewrites only request.systemInstruction.parts[].text", () => {
    const original = {
      model: "gemini-3.8-flash",
      request: {
        contents: [{ role: "user", parts: [{ text: "Oh My Pi <critical> omp Live" }] }],
        tools: [{ functionDeclarations: [{ name: "tool", description: "Oh My Pi <critical>" }] }],
        systemInstruction: {
          role: "user",
          parts: [
            {
              text: "Oh My Pi coding harness <system-conventions> <system_directive> <critical> omp Live",
            },
            { text: "Oh My Pi <critical>" },
            { inlineData: "Oh My Pi <critical>" },
          ],
        },
      },
    };

    const rewritten = rewriteSystemInstructionParts(original) as typeof original;

    expect(rewritten.request.systemInstruction.parts[0]).toEqual({
      text: "AI coding assistant <conventions> <instructions> <important> coding assistant live",
    });
    expect(rewritten.request.systemInstruction.parts[1]).toEqual({
      text: "coding assistant <important>",
    });
    expect(rewritten.request.systemInstruction.parts[2]).toEqual({
      inlineData: "Oh My Pi <critical>",
    });
    expect(rewritten.request.contents[0]?.parts[0]?.text).toBe("Oh My Pi <critical> omp Live");
    expect(rewritten.request.tools[0]?.functionDeclarations[0]?.description).toBe(
      "Oh My Pi <critical>",
    );
    expect(original.request.systemInstruction.parts[0]?.text).toContain("system-conventions");
  });
});

describe("proxy request handling", () => {
  it("preserves numeric literals and formatting outside rewritten system strings", async () => {
    let forwarded = "";
    const handler = createProxyHandler({
      upstreamFetch: async (input, init) => {
        forwarded = await new Request(input, init).text();
        return new Response(null, { status: 204 });
      },
    });
    const raw =
      '{ "request": {"systemInstruction":{"parts":[{"text":"Oh My Pi"}]}, "contents":[{"id":9007199254740993,"value":1e400,"text":"Oh My Pi"}]}}';
    const response = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: raw,
      }),
    );
    expect(response.status).toBe(204);
    expect(forwarded).toBe(raw.replace('"text":"Oh My Pi"', '"text":"coding assistant"'));
  });

  it("cancels upstream work when the client disconnects before response headers", async () => {
    let entered!: () => void;
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let finish!: (response: Response) => void;
    let upstreamSignal: AbortSignal | undefined;
    const sidecar = await listenSidecar({
      port: 0,
      upstreamFetch: async (_input, init) => {
        upstreamSignal = init?.signal ?? undefined;
        entered();
        return new Promise<Response>((resolve) => {
          finish = resolve;
        });
      },
    });
    const controller = new AbortController();
    const client = fetch(`${sidecar.url}${STREAM_PATH}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
      signal: controller.signal,
    }).catch(() => undefined);
    try {
      await started;
      controller.abort();
      await client;
      await new Promise((resolve) => setTimeout(resolve, 50));
      expect(upstreamSignal?.aborted).toBe(true);
    } finally {
      finish(new Response(null, { status: 204 }));
      sidecar.server.closeAllConnections();
      await sidecar.close();
    }
  });

  it("forwards the fixed upstream path and query while preserving non-target data", async () => {
    let capturedUrl = "";
    let capturedInit: RequestInit | undefined;
    const upstreamFetch: FetchLike = async (input, init) => {
      capturedUrl = input instanceof Request ? input.url : input.toString();
      capturedInit = init;
      return new Response("ok", {
        status: 429,
        headers: {
          "content-type": "text/plain",
          "content-length": "2",
          "content-encoding": "gzip",
          connection: "close, x-response-hop",
          "x-response-hop": "drop",
          "x-upstream": "kept",
        },
      });
    };
    const handler = createProxyHandler({ upstreamFetch });
    const requestBody = {
      request: {
        contents: [{ parts: [{ text: "Oh My Pi <critical>" }] }],
        tools: [{ functionDeclarations: [{ description: "Oh My Pi <critical>" }] }],
        systemInstruction: { parts: [{ text: "<system-conventions>" }] },
      },
    };
    const response = await handler(
      jsonRequest(`${STREAM_PATH}?alt=sse&trace=kept`, requestBody, {
        headers: {
          authorization: "Bearer test-token",
          "user-agent": "omp-test-agent",
          "x-client-metadata": "unchanged",
          connection: "keep-alive, x-request-hop",
          "x-request-hop": "drop",
          "content-length": "999",
          "content-encoding": "identity",
        },
      }),
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("x-upstream")).toBe("kept");
    expect(response.headers.get("content-length")).toBeNull();
    expect(response.headers.get("content-encoding")).toBeNull();
    expect(response.headers.get("connection")).toBeNull();
    expect(response.headers.get("x-response-hop")).toBeNull();
    expect(await response.text()).toBe("ok");
    expect(capturedUrl).toBe(`${DEFAULT_UPSTREAM_ORIGIN}${STREAM_PATH}?alt=sse&trace=kept`);
    expect(capturedInit?.redirect).toBe("error");

    const forwarded = await forwardedRequest(capturedUrl, capturedInit);
    const forwardedBody = (await forwarded.json()) as typeof requestBody;
    expect(forwarded.headers.get("authorization")).toBe("Bearer test-token");
    expect(forwarded.headers.get("user-agent")).toBe("omp-test-agent");
    expect(forwarded.headers.get("x-client-metadata")).toBe("unchanged");
    expect(forwarded.headers.get("connection")).toBeNull();
    expect(forwarded.headers.get("x-request-hop")).toBeNull();
    expect(forwarded.headers.get("content-length")).toBeNull();
    expect(new Headers(capturedInit?.headers).get("content-encoding")).toBeNull();
    expect(forwardedBody.request.contents[0]?.parts[0]?.text).toBe("Oh My Pi <critical>");
    expect(forwardedBody.request.tools[0]?.functionDeclarations[0]?.description).toBe(
      "Oh My Pi <critical>",
    );
    expect(forwardedBody.request.systemInstruction.parts[0]?.text).toBe("<conventions>");
  });

  it("runs through a real local HTTP server and streams SSE chunks", async () => {
    const firstChunk = new TextEncoder().encode("data: one\n\n");
    let releaseSecond!: () => void;
    const secondReady = new Promise<void>((resolve) => {
      releaseSecond = resolve;
    });
    const upstreamFetch: FetchLike = async () =>
      new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            controller.enqueue(firstChunk);
            await secondReady;
            controller.enqueue(new TextEncoder().encode("data: two\n\n"));
            controller.close();
          },
        }),
        { status: 200, headers: { "content-type": "text/event-stream" } },
      );
    const sidecar = await listenSidecar({ port: 0, upstreamFetch });

    try {
      const response = await fetch(`${sidecar.url}${STREAM_PATH}?alt=sse`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          request: { systemInstruction: { parts: [{ text: "<critical>" }] } },
        }),
      });
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toContain("text/event-stream");
      if (!response.body) throw new Error("SSE response has no body");
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let received = "";
      while (!received.endsWith("\n\n")) {
        const chunk = await reader.read();
        if (chunk.done) break;
        received += decoder.decode(chunk.value, { stream: true });
      }
      expect(received).toBe("data: one\n\n");
      releaseSecond();
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        received += decoder.decode(chunk.value, { stream: true });
      }
      expect(received + decoder.decode()).toBe("data: one\n\ndata: two\n\n");
    } finally {
      releaseSecond();
      sidecar.server.closeAllConnections();
      await sidecar.close();
    }
  });

  it("returns explicit client errors without contacting upstream", async () => {
    let calls = 0;
    const upstreamFetch: FetchLike = async () => {
      calls += 1;
      return new Response("unexpected");
    };
    const handler = createProxyHandler({ upstreamFetch, maxBodyBytes: 32 });

    const invalidJson = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{not-json",
      }),
    );
    expect(invalidJson.status).toBe(400);
    expect(await invalidJson.json()).toMatchObject({ error: { code: 400 } });

    const invalidWithoutContentType = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        body: new TextEncoder().encode("{not-json"),
      }),
    );
    expect(invalidWithoutContentType.status).toBe(400);

    const unsupportedContentType = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "text/plain" },
        body: "{}",
      }),
    );
    expect(unsupportedContentType.status).toBe(415);

    const emptyJson = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
      }),
    );
    expect(emptyJson.status).toBe(400);

    const forbidden = await handler(
      new Request("http://127.0.0.1/proxy?target=https%3A%2F%2Fevil.example", { method: "POST" }),
    );
    expect(forbidden.status).toBe(404);

    const oversized = await handler(
      jsonRequest(STREAM_PATH, {
        request: { systemInstruction: { parts: [{ text: "too large" }] } },
      }),
    );
    expect(oversized.status).toBe(413);
    expect(calls).toBe(0);
  });

  it("forwards upstream statuses and returns a generic network error", async () => {
    for (const status of [401, 429, 500]) {
      const handler = createProxyHandler({
        upstreamFetch: async () => new Response(JSON.stringify({ status }), { status }),
      });
      const response = await handler(jsonRequest(STREAM_PATH, {}));
      expect(response.status).toBe(status);
      expect(await response.json()).toEqual({ status });
    }

    const failed = createProxyHandler({
      upstreamFetch: async () => {
        throw new Error("credential-value-must-not-leak");
      },
    });
    const response = await failed(jsonRequest(STREAM_PATH, {}));
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("credential-value-must-not-leak");
  });

  it("allows the provider generation and discovery paths only", async () => {
    const paths = [
      "/v1internal:fetchAvailableModels",
      "/v1internal:retrieveUserQuota",
      "/v1internal:loadCodeAssist",
      "/v1internal:onboardUser",
    ];
    const seen: string[] = [];
    const handler = createProxyHandler({
      upstreamFetch: async (input) => {
        seen.push(input instanceof Request ? input.url : input.toString());
        return new Response(null, { status: 204 });
      },
    });

    for (const path of paths) {
      expect((await handler(jsonRequest(`${path}?keep=query`, {}))).status).toBe(204);
    }
    expect(
      (
        await handler(
          new Request("http://127.0.0.1/v1internal/operations/abc123", { method: "GET" }),
        )
      ).status,
    ).toBe(204);
    expect(
      (
        await handler(
          new Request("http://127.0.0.1/v1internal:streamGenerateContent", { method: "GET" }),
        )
      ).status,
    ).toBe(405);
    expect(seen).toEqual([
      ...paths.map((path) => `${DEFAULT_UPSTREAM_ORIGIN}${path}?keep=query`),
      `${DEFAULT_UPSTREAM_ORIGIN}/v1internal/operations/abc123`,
    ]);
  });

  it("passes cancellation to the upstream stream", async () => {
    let upstreamSignal: AbortSignal | undefined;
    let cancelled = false;
    const upstreamFetch: FetchLike = async (_input, init) => {
      upstreamSignal = init?.signal ?? undefined;
      return new Response(
        new ReadableStream<Uint8Array>({
          cancel() {
            cancelled = true;
          },
        }),
      );
    };
    const controller = new AbortController();
    const handler = createProxyHandler({ upstreamFetch });
    const response = await handler(
      jsonRequest(
        STREAM_PATH,
        { request: { systemInstruction: { parts: [{ text: "hello" }] } } },
        { signal: controller.signal },
      ),
    );
    const reader = response.body?.getReader();
    controller.abort();
    await reader?.cancel();
    expect(upstreamSignal?.aborted).toBe(true);
    expect(cancelled).toBe(true);
  });

  it("transforms large payloads efficiently without mutating contents strings", async () => {
    let forwardedText = "";
    const handler = createProxyHandler({
      upstreamFetch: async (input, init) => {
        forwardedText = await new Request(input, init).text();
        return new Response(null, { status: 204 });
      },
    });

    const largePayload = {
      request: {
        systemInstruction: {
          role: "user",
          parts: [{ text: "Oh My Pi coding harness with <critical> instructions" }],
        },
        contents: Array.from({ length: 1000 }, (_, i) => ({
          role: i % 2 === 0 ? "user" : "model",
          parts: [
            {
              text: `Message ${i}: This mentions "systemInstruction" and Oh My Pi in user text and code: ` +
                "x".repeat(1000),
            },
          ],
        })),
      },
    };

    const raw = JSON.stringify(largePayload);
    const startTime = performance.now();
    const response = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: raw,
      }),
    );
    const duration = performance.now() - startTime;

    expect(response.status).toBe(204);
    expect(duration).toBeLessThan(100);
    const parsedForwarded = JSON.parse(forwardedText);
    expect(parsedForwarded.request.systemInstruction.parts[0].text).toBe(
      "AI coding assistant with <important> instructions",
    );
    expect(parsedForwarded.request.contents[0].parts[0].text).toContain("Oh My Pi in user text");
  });

  it("only rewrites request.systemInstruction and preserves nested systemInstruction keys in contents", async () => {
    let forwardedText = "";
    const handler = createProxyHandler({
      upstreamFetch: async (input, init) => {
        forwardedText = await new Request(input, init).text();
        return new Response(null, { status: 204 });
      },
    });

    const payload = {
      request: {
        contents: [
          {
            systemInstruction: {
              parts: [{ text: "Oh My Pi in contents must not be rewritten" }],
            },
          },
        ],
        systemInstruction: {
          parts: [{ text: "Oh My Pi in request must be rewritten" }],
        },
      },
    };

    const response = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      }),
    );

    expect(response.status).toBe(204);
    const parsed = JSON.parse(forwardedText);
    expect(parsed.request.systemInstruction.parts[0].text).toBe(
      "coding assistant in request must be rewritten",
    );
    expect(parsed.request.contents[0].systemInstruction.parts[0].text).toBe(
      "Oh My Pi in contents must not be rewritten",
    );
  });

  it("handles escaped unicode keys in systemInstruction", async () => {
    let forwardedText = "";
    const handler = createProxyHandler({
      upstreamFetch: async (input, init) => {
        forwardedText = await new Request(input, init).text();
        return new Response(null, { status: 204 });
      },
    });

    const raw =
      '{"request":{"systemInstruct\\u0069on":{"parts":[{"text":"Oh My Pi"}]},"contents":[]}}';
    const response = await handler(
      new Request(`http://127.0.0.1${STREAM_PATH}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: raw,
      }),
    );

    expect(response.status).toBe(204);
    const parsed = JSON.parse(forwardedText);
    expect(parsed.request.systemInstruction.parts[0].text).toBe("coding assistant");
  });
});
