import { afterEach, describe, expect, test } from "vite-plus/test";
import {
  computeDelayMs,
  DEFAULT_ATTEMPT_TIMEOUT_MS,
  DEFAULT_BASE_DELAY_MS,
  DEFAULT_BUDGET_MS,
  DEFAULT_MAX_ATTEMPTS,
  DEFAULT_MAX_DELAY_MS,
  fetchWithRetry,
} from "../src/http.js";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("fetchWithRetry", () => {
  test("exports standard default constants", () => {
    expect(DEFAULT_MAX_ATTEMPTS).toBe(4);
    expect(DEFAULT_BASE_DELAY_MS).toBe(250);
    expect(DEFAULT_MAX_DELAY_MS).toBe(4000);
    expect(DEFAULT_ATTEMPT_TIMEOUT_MS).toBe(30_000);
    expect(DEFAULT_BUDGET_MS).toBe(45_000);
  });

  test("retries on 504 and returns the final 200 response when upstream recovers", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      if (calls < 3) {
        return new Response("gateway timeout", { status: 504 });
      }
      return new Response("ok", { status: 200 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(calls).toBe(3);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
  });

  test("does not retry 404 and returns the response immediately", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      return new Response("not found", { status: 404 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(calls).toBe(1);
    expect(response.status).toBe(404);
  });

  test("does not retry 302 and returns the redirect response immediately", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      return new Response(null, {
        status: 302,
        headers: { location: "https://example.com/download" },
      });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry(
      "https://example.com/redirect",
      { redirect: "manual" },
      { baseDelayMs: 0, maxDelayMs: 0 },
    );

    expect(calls).toBe(1);
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("https://example.com/download");
  });

  test("retries on 429 with Retry-After: 0 header and honors the delay", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      if (calls === 1) {
        return new Response("rate limited", {
          status: 429,
          headers: { "retry-after": "0" },
        });
      }
      return new Response("ok", { status: 200 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 1000,
      maxDelayMs: 4000,
    });

    expect(calls).toBe(2);
    expect(response.status).toBe(200);
    expect(computeDelayMs(1, new Response(null, { headers: { "retry-after": "0" } }))).toBe(0);
  });

  test("falls back to exponential backoff when Retry-After is unparseable or expired", async () => {
    const unparseableResponse = new Response(null, {
      status: 429,
      headers: { "retry-after": "not-a-valid-date-or-seconds" },
    });
    const unparseableDelay = computeDelayMs(1, unparseableResponse, 100, 1000);
    expect(unparseableDelay).toBeGreaterThanOrEqual(100);
    expect(unparseableDelay).toBeLessThanOrEqual(200);

    const expiredResponse = new Response(null, {
      status: 429,
      headers: { "retry-after": new Date(Date.now() - 60_000).toUTCString() },
    });
    const expiredDelay = computeDelayMs(1, expiredResponse, 100, 1000);
    expect(expiredDelay).toBeGreaterThanOrEqual(100);
    expect(expiredDelay).toBeLessThanOrEqual(200);

    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      if (calls === 1) {
        return unparseableResponse;
      }
      return new Response("ok", { status: 200 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });
    expect(calls).toBe(2);
    expect(response.status).toBe(200);
  });

  test("clamps Retry-After to max delay when it exceeds the limit", async () => {
    const largeSecondsResponse = new Response(null, {
      status: 429,
      headers: { "retry-after": "3600" },
    });
    expect(computeDelayMs(1, largeSecondsResponse, 100, 500)).toBe(500);

    const largeDateResponse = new Response(null, {
      status: 429,
      headers: { "retry-after": new Date(Date.now() + 3_600_000).toUTCString() },
    });
    expect(computeDelayMs(1, largeDateResponse, 100, 500)).toBe(500);

    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      if (calls === 1) {
        return largeSecondsResponse;
      }
      return new Response("ok", { status: 200 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });
    expect(calls).toBe(2);
    expect(response.status).toBe(200);
  });

  test("stops after max attempts when upstream continuously returns 503 and returns the last 503", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      return new Response("service unavailable", { status: 503 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      maxAttempts: 3,
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(calls).toBe(3);
    expect(response.status).toBe(503);
    expect(await response.text()).toBe("service unavailable");
  });

  test("rethrows the last error when fetch continuously throws", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      throw new TypeError("fetch failed: network connection dropped");
    }) as typeof globalThis.fetch;

    await expect(
      fetchWithRetry("https://example.com/api", undefined, {
        maxAttempts: 3,
        baseDelayMs: 0,
        maxDelayMs: 0,
      }),
    ).rejects.toThrow("network connection dropped");

    expect(calls).toBe(3);
  });

  test("passes a distinct AbortSignal to each attempt even if previous attempt signal was aborted", async () => {
    const signals: AbortSignal[] = [];
    globalThis.fetch = (async (_input: unknown, init?: RequestInit) => {
      if (init?.signal) {
        signals.push(init.signal);
      }
      if (signals.length === 1) {
        throw new DOMException("The operation was aborted.", "AbortError");
      }
      return new Response("ok", { status: 200 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });
    expect(signals).toHaveLength(2);
    expect(signals[0]).not.toBe(signals[1]);
    expect(signals[1]?.aborted).toBe(false);
    expect(response.status).toBe(200);
  });
  test("stops when wall-clock budget is spent even if attempts remain and returns the last response", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      // Real timer exercises the wall-clock budget comparison against platform time.
      const { promise, resolve } = Promise.withResolvers<void>();
      setTimeout(resolve, 20);
      await promise;
      return new Response("still busy", { status: 503 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      maxAttempts: 5,
      budgetMs: 10,
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(calls).toBe(1);
    expect(response.status).toBe(503);
  });

  test("retries when response body stream throws an error mid-stream and delivers readable final body", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      if (calls === 1) {
        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.error(new Error("socket closed mid-transfer"));
          },
        });
        return new Response(stream, { status: 200 });
      }
      return new Response("complete body content", { status: 200 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(calls).toBe(2);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("complete body content");
  });

  test("reconstructed response preserves body, status, and headers for caller", async () => {
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ name: "tool", version: "1.2.3" }), {
        status: 200,
        headers: {
          "content-type": "application/json",
          "x-custom-release-lock": "verified",
        },
      })) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/meta", undefined, {
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(response.headers.get("x-custom-release-lock")).toBe("verified");
    const json = (await response.json()) as { name: string; version: string };
    expect(json).toEqual({ name: "tool", version: "1.2.3" });
  });

  test("does not retry when maxAttempts is configured to 1", async () => {
    let calls = 0;
    globalThis.fetch = (async () => {
      calls++;
      return new Response("internal error", { status: 500 });
    }) as typeof globalThis.fetch;

    const response = await fetchWithRetry("https://example.com/api", undefined, {
      maxAttempts: 1,
      baseDelayMs: 0,
      maxDelayMs: 0,
    });

    expect(calls).toBe(1);
    expect(response.status).toBe(500);
  });
});
