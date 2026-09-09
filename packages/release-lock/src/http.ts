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

export function computeDelayMs(
  attempt: number,
  response: Response | undefined,
  baseDelayMs = DEFAULT_BASE_DELAY_MS,
  maxDelayMs = DEFAULT_MAX_DELAY_MS,
): number {
  if (response) {
    const retryAfter = response.headers.get("retry-after");
    if (retryAfter !== null && retryAfter.trim() !== "") {
      const trimmed = retryAfter.trim();
      if (/^\d+$/.test(trimmed)) {
        const seconds = parseInt(trimmed, 10);
        return Math.min(Math.max(0, seconds * 1000), maxDelayMs);
      }
      const dateMs = Date.parse(trimmed);
      if (!Number.isNaN(dateMs)) {
        const diffMs = dateMs - Date.now();
        if (diffMs > 0) {
          return Math.min(diffMs, maxDelayMs);
        }
      }
    }
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
  let lastResponse: Response | undefined;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    if (attempt > 1 && Date.now() - startTime >= budgetMs) {
      break;
    }

    let currentResponse: Response | undefined;
    try {
      const signal = AbortSignal.timeout(attemptTimeoutMs);
      const attemptInit: RequestInit = { ...init, signal };
      const rawResponse = await fetch(url, attemptInit);
      const response = await bufferResponse(rawResponse);

      if (!isRetryableStatus(response.status)) {
        return response;
      }

      currentResponse = response;
      lastResponse = response;
    } catch (error) {
      lastError = error;
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

    const delayMs = computeDelayMs(attempt, currentResponse, baseDelayMs, maxDelayMs);
    const sleepMs = Math.min(delayMs, remainingBudget);
    if (sleepMs > 0) {
      const { promise, resolve } = Promise.withResolvers<void>();
      setTimeout(resolve, sleepMs);
      await promise;
    }

    if (Date.now() - startTime >= budgetMs) {
      break;
    }
  }

  if (lastResponse) {
    return lastResponse;
  }
  throw lastError;
}
