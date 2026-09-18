import { describe, expect, test } from "vite-plus/test";
import { type DecideInput, decideDispatch } from "../src/decide.js";
import type { Marker } from "../src/marker.js";

const DEFAULT_MARKER: Marker = {
  target: "compound-engineering-v3.26.3",
  status: "idle",
  attempts: 0,
  firstAttempt: null,
  lastAttempt: null,
  notBefore: null,
  failureClass: null,
  missing: [],
  issue: null,
};

const t0 = new Date("2026-09-19T12:00:00.000Z");

describe("decideDispatch", () => {
  test("dispatches when all conditions are clear", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("dispatch");
  });

  test("skips when gateClass is valid (patches already work)", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "valid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/already valid/i);
  });

  test("skips when gateClass is upstream-unavailable", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "upstream-unavailable",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/upstream unavailable/i);
  });

  test("skips when resolvedTag is not newer than pin", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.26.3",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/not newer/i);
  });

  test("skips when state query failed", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
      stateQueryFailed: true,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/failed state query/i);
  });

  test("skips for a run in progress", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [{ status: "in_progress" }],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/in progress/i);
  });

  test("skips for a queued run", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [{ status: "queued" }],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/queued/i);
  });

  test("skips for a healthy pull request (targeting resolvedTag, < 2h old, autoMerge true)", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [
        {
          number: 101,
          headRefName: "chore/rebase-ce-overlays-v3.27.0",
          targetTag: "compound-engineering-v3.27.0",
          createdAt: new Date(t0.getTime() - 30 * 60 * 1000).toISOString(), // 30m ago
          autoMergeEnabled: true,
        },
      ],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/healthy/i);
  });

  test("skips for future notBefore", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "deferred",
        notBefore: new Date(t0.getTime() + 60 * 60 * 1000).toISOString(), // 1h in future
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/notBefore/i);
  });

  test("skips for escalated marker with an open issue", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "escalated",
        issue: 42,
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: { number: 42, state: "open", title: "CE rebase tracking" },
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/tracking issue/i);
  });

  test("skips for escalated marker when no tracking issue exists", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "escalated",
        issue: null,
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/escalated/i);
  });

  test("skips for blocked-config marker when no tracking issue exists", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "blocked-config",
        failureClass: "configuration",
        missing: ["P1"],
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/configuration/i);
  });

  test("skips for open tracking issue with an idle marker", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: { number: 42, state: "open", title: "CE rebase tracking" },
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/tracking issue/i);
  });

  test("dispatches when an escalated marker's issue is closed", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "escalated",
        issue: 42,
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: { number: 42, state: "closed", title: "CE rebase tracking" },
      now: t0,
    });
    expect(result.action).toBe("dispatch");
  });

  test("closes then dispatches for a pull request that targets an older tag", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.28.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [
        {
          number: 99,
          headRefName: "chore/rebase-ce-overlays-v3.27.0",
          targetTag: "compound-engineering-v3.27.0",
          createdAt: new Date(t0.getTime() - 10 * 60 * 1000).toISOString(),
          autoMergeEnabled: true,
        },
      ],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("close-then-dispatch");
    expect(result.closePrNumbers).toEqual([99]);
    expect(result.reason).toMatch(/older tag|superseded/i);
  });

  test("closes then dispatches for PR 2 hours old with no run in progress", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: DEFAULT_MARKER,
      rebaseRuns: [],
      openPullRequests: [
        {
          number: 105,
          headRefName: "chore/rebase-ce-overlays-v3.27.0",
          targetTag: "compound-engineering-v3.27.0",
          createdAt: new Date(t0.getTime() - 2 * 60 * 60 * 1000 - 1000).toISOString(), // 2h1s ago
          autoMergeEnabled: true,
        },
      ],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("close-then-dispatch");
    expect(result.closePrNumbers).toEqual([105]);
    expect(result.reason).toMatch(/orphaned|2 hours/i);
  });

  test("awaiting-review marker with open PR for resolved tag skips at any age", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "awaiting-review",
      },
      rebaseRuns: [],
      openPullRequests: [
        {
          number: 106,
          headRefName: "chore/rebase-ce-overlays-v3.27.0",
          targetTag: "compound-engineering-v3.27.0",
          createdAt: new Date(t0.getTime() - 48 * 60 * 60 * 1000).toISOString(), // 48h ago
          autoMergeEnabled: false,
        },
      ],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("skip");
    expect(result.reason).toMatch(/awaiting-review|awaiting review/i);
  });

  test("awaiting-review marker with no open PR for the resolved tag skips after the owner closes it", () => {
    const base: Omit<DecideInput, "openPullRequests"> = {
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "awaiting-review",
      },
      rebaseRuns: [],
      trackingIssue: null,
      now: t0,
    };

    const closed = decideDispatch({ ...base, openPullRequests: [] });
    expect(closed.action).toBe("skip");
    expect(closed.reason).toMatch(/closed/i);

    const other = decideDispatch({
      ...base,
      openPullRequests: [
        {
          number: 107,
          headRefName: "chore/rebase-ce-overlays-v3.26.9",
          targetTag: "compound-engineering-v3.26.9",
          createdAt: new Date(t0.getTime() - 48 * 60 * 60 * 1000).toISOString(),
          autoMergeEnabled: false,
        },
      ],
    });
    expect(other.action).toBe("skip");
    expect(other.reason).toMatch(/closed/i);
  });

  test("awaiting-review marker for an older target still dispatches with no open PR", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.28.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "awaiting-review",
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("dispatch");
  });

  test("stored marker whose target is older than resolvedTag is treated as idle", () => {
    const result = decideDispatch({
      resolvedTag: "compound-engineering-v3.28.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        ...DEFAULT_MARKER,
        target: "compound-engineering-v3.27.0",
        status: "deferred",
        notBefore: new Date(t0.getTime() + 5 * 60 * 60 * 1000).toISOString(), // future notBefore for old target!
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
      now: t0,
    });
    expect(result.action).toBe("dispatch");
  });
});
