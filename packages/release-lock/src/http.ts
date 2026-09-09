import { setTimeout as sleep } from "node:timers/promises";

/**
 * Shared HTTP fetch wrapper with exponential backoff retry.
 *
 * Transient upstream failures (network drops, 408/425/429/5xx) during hourly
 * release lock resolution would otherwise fail the workflow run and trigger
 * operator alerts for temporary hiccups. This wrapper retries transient errors
 * with jittered backoff or Retry-After delays while preserving non-retryable
 * responses (2xx, 3xx redirects, 404) immediately for resolver handling.
 */

export const DEFAULT_MAX_ATTEMPTS = 4;
export const DEFAULT_BASE_DELAY_MS = 250;
export const DEFAULT_MAX_DELAY_MS = 4000;
export const DEFAULT_ATTEMPT_TIMEOUT_MS = 30_000;
export const DEFAULT_BUDGET_MS = 45_000;

export interface RetryOptions {
  readonly maxAttempts?: number | undefined;
  readonly baseDelayMs?: number | undefined;
  readonly maxDelayMs?: number | undefined;
  readonly attemptTimeoutMs?: number | undefined;
  readonly budgetMs?: number | undefined;
}
function isRetryableStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || (status >= 500 && status <= 599);
}

function isNullBodyStatus(status: number): boolean {
  return status === 101 || status === 204 || status === 205 || status === 304;
}

/** The cooldown the server itself named, in ms, or null when it named none. */
export function serverNamedDelayMs(response: Response | undefined): number | null {
  const retryAfter = response?.headers.get("retry-after")?.trim();
  if (!retryAfter) return null;
  if (/^\d+$/.test(retryAfter)) {
    return parseInt(retryAfter, 10) * 1000;
  }
  const dateMs = Date.parse(retryAfter);
  if (!Number.isNaN(dateMs) && dateMs > Date.now()) {
    return dateMs - Date.now();
  }
  return null;
}

export function computeDelayMs(
  attempt: number,
  response: Response | undefined,
  baseDelayMs = DEFAULT_BASE_DELAY_MS,
  maxDelayMs = DEFAULT_MAX_DELAY_MS,
): number {
  const named = serverNamedDelayMs(response);
  if (named !== null) {
    return Math.min(named, maxDelayMs);
  }

  const backoff = baseDelayMs * 2 ** Math.max(0, attempt - 1);
  const jitter = baseDelayMs > 0 ? Math.random() * baseDelayMs : 0;
  return Math.min(maxDelayMs, backoff + jitter);
}

async function bufferResponse(response: Response): Promise<Response> {
  let body: ArrayBuffer | null = null;
  if (response.body !== null && !isNullBodyStatus(response.status)) {
    body = await response.arrayBuffer();
  }
  const reconstructed = new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
  if (response.url) {
    try {
      Object.defineProperty(reconstructed, "url", { value: response.url });
    } catch {
      // url definition ignored if unsupported
    }
  }
  return reconstructed;
}

export async function fetchWithRetry(
  url: string | URL | Request,
  init?: RequestInit,
  options?: RetryOptions,
): Promise<Response> {
  const maxAttempts = Math.max(1, options?.maxAttempts ?? DEFAULT_MAX_ATTEMPTS);
  const baseDelayMs = options?.baseDelayMs ?? DEFAULT_BASE_DELAY_MS;
  const maxDelayMs = options?.maxDelayMs ?? DEFAULT_MAX_DELAY_MS;
  const attemptTimeoutMs = options?.attemptTimeoutMs ?? DEFAULT_ATTEMPT_TIMEOUT_MS;
  const budgetMs = options?.budgetMs ?? DEFAULT_BUDGET_MS;

  const startTime = Date.now();
  let lastOutcome: { response: Response } | { error: unknown } | undefined;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    // The attempt's own timeout is clamped to what is left of the budget, so a
    // hanging upstream cannot spend a full attempt timeout past the deadline.
    const remainingBefore = budgetMs - (Date.now() - startTime);
    if (attempt > 1 && remainingBefore <= 0) {
      break;
    }

    let currentResponse: Response | undefined;
    try {
      const signal = AbortSignal.timeout(Math.min(attemptTimeoutMs, Math.max(1, remainingBefore)));
      const attemptInit: RequestInit = { ...init, signal };
      const rawResponse = await fetch(url, attemptInit);
      const response = await bufferResponse(rawResponse);

      if (!isRetryableStatus(response.status)) {
        return response;
      }

      currentResponse = response;
      lastOutcome = { response };
    } catch (error) {
      lastOutcome = { error };
      currentResponse = undefined;
    }

    if (attempt >= maxAttempts) {
      break;
    }

    const elapsed = Date.now() - startTime;
    const remainingBudget = budgetMs - elapsed;
    if (remainingBudget <= 0) {
      break;
    }

    // A cooldown longer than this call can honor makes every remaining attempt
    // a request inside the window the server just asked us to stay out of.
    const named = serverNamedDelayMs(currentResponse);
    if (currentResponse && named !== null && named > Math.min(maxDelayMs, remainingBudget)) {
      return currentResponse;
    }

    const delayMs = computeDelayMs(attempt, currentResponse, baseDelayMs, maxDelayMs);
    const sleepMs = Math.min(delayMs, remainingBudget);
    if (sleepMs > 0) {
      await sleep(sleepMs);
    }
  }

  // The caller sees the LAST attempt's outcome, never an earlier response that
  // a later network failure superseded.
  if (lastOutcome && "response" in lastOutcome) {
    return lastOutcome.response;
  }
  throw lastOutcome?.error;
}
