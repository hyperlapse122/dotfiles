import { join } from "node:path";
import { describe, expect, test } from "vite-plus/test";
import { classifyFailure } from "../src/classify.js";

describe("classifyFailure", () => {
  test("matches rate_limit and usage_limit signals as quota", () => {
    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { type: "rate_limit_error", message: "Rate limit exceeded" },
        }),
      }),
    ).toBe("quota");

    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          status: 429,
          message: "Too many requests. Usage limit exceeded.",
        }),
      }),
    ).toBe("quota");
  });

  test("matches overload, 5xx, timeout, and connection signals as outage", () => {
    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { type: "overloaded_error", message: "Anthropic is overloaded" },
        }),
      }),
    ).toBe("outage");

    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          status: 503,
          message: "Service Unavailable",
        }),
      }),
    ).toBe("outage");

    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { message: "ETIMEDOUT: Connection timed out" },
        }),
      }),
    ).toBe("outage");

    expect(
      classifyFailure({
        actionConclusion: "timed_out",
      }),
    ).toBe("outage");

    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { message: "ECONNRESET: socket hang up" },
        }),
      }),
    ).toBe("outage");
  });

  test("matches authentication failures as configuration", () => {
    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { type: "authentication_error", status: 401, message: "Unauthorized" },
        }),
      }),
    ).toBe("configuration");

    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { message: "Invalid API key provided" },
        }),
      }),
    ).toBe("configuration");
  });

  test("matches caller fact for scope check or gate failure as genuine", () => {
    expect(
      classifyFailure({
        callerReason: "scope-check-failed",
      }),
    ).toBe("genuine");

    expect(
      classifyFailure({
        callerReason: "gate-failed",
      }),
    ).toBe("genuine");

    expect(
      classifyFailure({
        callerReason: "genuine",
      }),
    ).toBe("genuine");
  });

  test("returns unknown for missing file, malformed JSON, and unrecognized error", () => {
    // Missing file / null content
    expect(classifyFailure({})).toBe("unknown");
    expect(classifyFailure({ executionFileContent: null })).toBe("unknown");

    // Malformed JSON
    expect(classifyFailure({ executionFileContent: "not json at all" })).toBe("unknown");
    expect(classifyFailure({ executionFileContent: "{ unclosed json" })).toBe("unknown");

    // Unrecognized error
    expect(
      classifyFailure({
        executionFileContent: JSON.stringify({
          error: { type: "weird_custom_error", message: "unusual issue" },
        }),
      }),
    ).toBe("unknown");
  });

  test("caller value outside closed set maps to unknown", () => {
    expect(
      classifyFailure({
        callerReason: "non_existent_failure_class",
      }),
    ).toBe("unknown");
  });
});

describe("fixtures under .ci/fixtures/ce-overlay-rebase", () => {
  const fixturesDir = join(import.meta.dirname, "../../../.ci/fixtures/ce-overlay-rebase");

  test("quota fixtures classify as quota", () => {
    expect(classifyFailure({ executionFile: join(fixturesDir, "quota-rate-limit.json") })).toBe(
      "quota",
    );
    expect(classifyFailure({ executionFile: join(fixturesDir, "quota-429.json") })).toBe("quota");
  });

  test("outage fixtures classify as outage", () => {
    expect(classifyFailure({ executionFile: join(fixturesDir, "outage-overloaded.json") })).toBe(
      "outage",
    );
    expect(classifyFailure({ executionFile: join(fixturesDir, "outage-503.json") })).toBe("outage");
    expect(classifyFailure({ executionFile: join(fixturesDir, "outage-timeout.json") })).toBe(
      "outage",
    );
    expect(classifyFailure({ executionFile: join(fixturesDir, "outage-connection.json") })).toBe(
      "outage",
    );
  });

  test("config fixture classifies as configuration", () => {
    expect(classifyFailure({ executionFile: join(fixturesDir, "config-auth.json") })).toBe(
      "configuration",
    );
  });

  test("unknown and malformed fixtures classify as unknown", () => {
    expect(classifyFailure({ executionFile: join(fixturesDir, "unknown-unrecognized.json") })).toBe(
      "unknown",
    );
    expect(classifyFailure({ executionFile: join(fixturesDir, "malformed.json") })).toBe("unknown");
    expect(classifyFailure({ executionFile: join(fixturesDir, "nonexistent-file.json") })).toBe(
      "unknown",
    );
  });
});
