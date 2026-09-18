import { describe, expect, test } from "vite-plus/test";
import {
  FAILURE_CLASSES,
  MARKER_STATUSES,
  MISSING_PREREQUISITES,
  type Marker,
  type MarkerDocument,
  type MissingPrerequisite,
  createIdleMarker,
  resetMarker,
  transitionMarker,
  validateMarker,
  validateMarkerDocument,
} from "../src/marker.js";

const VALID_MARKER: Marker = {
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

describe("marker schema validation", () => {
  test("valid marker passes validation", () => {
    const res = validateMarker(VALID_MARKER);
    expect(res.valid).toBe(true);
    expect(res.errors).toHaveLength(0);
  });

  test("valid document with ceOverlayRebase wrapper passes", () => {
    const doc: MarkerDocument = { ceOverlayRebase: VALID_MARKER };
    const res = validateMarkerDocument(doc);
    expect(res.valid).toBe(true);
  });

  test("missing top-level ceOverlayRebase key fails document validation", () => {
    const res = validateMarkerDocument({ otherKey: VALID_MARKER });
    expect(res.valid).toBe(false);
    expect(res.errors[0]).toMatch(/ceOverlayRebase/);
  });

  test("missing key fails validation", () => {
    const copy: Record<string, unknown> = { ...VALID_MARKER };
    delete copy["issue"];
    const res = validateMarker(copy);
    expect(res.valid).toBe(false);
    expect(res.errors.some((e) => e.includes("issue"))).toBe(true);
  });

  test("unknown status fails validation", () => {
    const res = validateMarker({ ...VALID_MARKER, status: "in_progress" });
    expect(res.valid).toBe(false);
    expect(res.errors.some((e) => e.includes("status"))).toBe(true);
  });

  test("target outside compound-engineering-v<semver> form fails validation", () => {
    expect(validateMarker({ ...VALID_MARKER, target: "v1.0.0" }).valid).toBe(false);
    expect(validateMarker({ ...VALID_MARKER, target: "compound-engineering-1.0.0" }).valid).toBe(
      false,
    );
    expect(validateMarker({ ...VALID_MARKER, target: "compound-engineering-v" }).valid).toBe(false);
    expect(validateMarker({ ...VALID_MARKER, target: "compound-engineering-v1.0" }).valid).toBe(
      false,
    );
    expect(validateMarker({ ...VALID_MARKER, target: "" }).valid).toBe(false);
    expect(validateMarker({ ...VALID_MARKER, target: null as unknown as string }).valid).toBe(
      false,
    );
  });

  test("target in compound-engineering-v<semver> form passes validation", () => {
    expect(validateMarker({ ...VALID_MARKER, target: "compound-engineering-v3.26.3" }).valid).toBe(
      true,
    );
    expect(validateMarker({ ...VALID_MARKER, target: "compound-engineering-v0.1.0" }).valid).toBe(
      true,
    );
    expect(
      validateMarker({ ...VALID_MARKER, target: "compound-engineering-v10.20.30-alpha.1" }).valid,
    ).toBe(true);
  });

  test("missing value outside P1-P4 fails validation", () => {
    const res = validateMarker({
      ...VALID_MARKER,
      missing: ["P1", "P5" as unknown as MissingPrerequisite],
    });
    expect(res.valid).toBe(false);
    expect(res.errors.some((e) => e.includes("missing"))).toBe(true);
  });

  test("negative attempts fails validation", () => {
    const res = validateMarker({ ...VALID_MARKER, attempts: -1 });
    expect(res.valid).toBe(false);
  });

  test("invalid ISO timestamp fails validation", () => {
    const res = validateMarker({ ...VALID_MARKER, firstAttempt: "not-a-date" });
    expect(res.valid).toBe(false);
  });

  test("invalid issue number fails validation", () => {
    const res = validateMarker({ ...VALID_MARKER, issue: -5 });
    expect(res.valid).toBe(false);
  });

  test("closed sets match specification", () => {
    expect(MARKER_STATUSES).toEqual([
      "idle",
      "deferred",
      "escalated",
      "blocked-config",
      "awaiting-review",
    ]);
    expect(FAILURE_CLASSES).toEqual(["outage", "quota", "genuine", "unknown", "configuration"]);
    expect(MISSING_PREREQUISITES).toEqual(["P1", "P2", "P3", "P4"]);
  });
});

describe("marker state transitions", () => {
  const t0 = new Date("2026-09-19T10:00:00.000Z");

  test("outage from idle gives deferred, attempts 1, and notBefore 2h later", () => {
    const marker = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t0,
    });
    expect(marker.status).toBe("deferred");
    expect(marker.attempts).toBe(1);
    expect(marker.firstAttempt).toBe(t0.toISOString());
    expect(marker.lastAttempt).toBe(t0.toISOString());
    expect(marker.failureClass).toBe("outage");
    expect(marker.notBefore).toBe(new Date("2026-09-19T12:00:00.000Z").toISOString());
  });

  test("quota from idle gives deferred, attempts 1, and notBefore 6h later", () => {
    const marker = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "quota",
      reachedClaude: true,
      now: t0,
    });
    expect(marker.status).toBe("deferred");
    expect(marker.attempts).toBe(1);
    expect(marker.notBefore).toBe(new Date("2026-09-19T16:00:00.000Z").toISOString());
  });

  test("second outage attempt stays deferred with attempts 2", () => {
    const m1 = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t0,
    });
    const t1 = new Date("2026-09-19T12:30:00.000Z");
    const m2 = transitionMarker(m1, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t1,
    });
    expect(m2.status).toBe("deferred");
    expect(m2.attempts).toBe(2);
    expect(m2.firstAttempt).toBe(t0.toISOString());
    expect(m2.lastAttempt).toBe(t1.toISOString());
    expect(m2.notBefore).toBe(new Date("2026-09-19T14:30:00.000Z").toISOString());
  });

  test("third Claude attempt gives escalated", () => {
    const m1 = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t0,
    });
    const m2 = transitionMarker(m1, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: new Date("2026-09-19T12:30:00.000Z"),
    });
    const m3 = transitionMarker(m2, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: new Date("2026-09-19T15:00:00.000Z"),
      issue: 42,
    });
    expect(m3.status).toBe("escalated");
    expect(m3.attempts).toBe(3);
    expect(m3.issue).toBe(42);
    expect(m3.notBefore).toBeNull();
  });

  test("failure 24 hours after firstAttempt gives escalated", () => {
    const m1 = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t0,
    });
    const tLate = new Date("2026-09-20T10:01:00.000Z"); // 24h1m later
    const m2 = transitionMarker(m1, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: tLate,
    });
    expect(m2.status).toBe("escalated");
    expect(m2.attempts).toBe(2);
    expect(m2.notBefore).toBeNull();
  });

  test("genuine and unknown give escalated from any status", () => {
    const mGen = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "genuine",
      now: t0,
    });
    expect(mGen.status).toBe("escalated");
    expect(mGen.failureClass).toBe("genuine");

    const mUnk = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "unknown",
      now: t0,
    });
    expect(mUnk.status).toBe("escalated");
    expect(mUnk.failureClass).toBe("unknown");
  });

  test("configuration gives blocked-config with missing names and no attempt increment", () => {
    const mConfig = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "configuration",
      missing: ["P1", "P3"],
      reachedClaude: false,
      now: t0,
    });
    expect(mConfig.status).toBe("blocked-config");
    expect(mConfig.failureClass).toBe("configuration");
    expect(mConfig.missing).toEqual(["P1", "P3"]);
    expect(mConfig.attempts).toBe(0);
  });

  test("failure for a newer target resets attempts and timestamps", () => {
    const mOld = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t0,
    });
    expect(mOld.attempts).toBe(1);

    const tNew = new Date("2026-09-20T10:00:00.000Z");
    const mNew = transitionMarker(mOld, {
      type: "failure",
      target: "compound-engineering-v3.28.0",
      failureClass: "quota",
      reachedClaude: true,
      now: tNew,
    });
    expect(mNew.target).toBe("compound-engineering-v3.28.0");
    expect(mNew.attempts).toBe(1);
    expect(mNew.firstAttempt).toBe(tNew.toISOString());
    expect(mNew.status).toBe("deferred");
  });

  test("manual trigger restarts the count", () => {
    const m1 = transitionMarker(VALID_MARKER, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      now: t0,
    });
    const m2 = transitionMarker(m1, {
      type: "failure",
      target: "compound-engineering-v3.27.0",
      failureClass: "outage",
      reachedClaude: true,
      manualTrigger: true,
      now: new Date("2026-09-19T14:00:00.000Z"),
    });
    expect(m2.attempts).toBe(1);
    expect(m2.firstAttempt).toBe(new Date("2026-09-19T14:00:00.000Z").toISOString());
  });

  test("awaiting-review transition sets status", () => {
    const mRev = transitionMarker(VALID_MARKER, {
      type: "awaiting-review",
      target: "compound-engineering-v3.27.0",
      now: t0,
    });
    expect(mRev.status).toBe("awaiting-review");
    expect(mRev.notBefore).toBeNull();
  });

  test("resetMarker returns clean idle marker", () => {
    const idle = resetMarker("compound-engineering-v3.27.0");
    expect(idle.status).toBe("idle");
    expect(idle.target).toBe("compound-engineering-v3.27.0");
    expect(idle.attempts).toBe(0);
    expect(idle.firstAttempt).toBeNull();
    expect(idle.lastAttempt).toBeNull();
    expect(idle.notBefore).toBeNull();
    expect(idle.failureClass).toBeNull();
    expect(idle.missing).toEqual([]);
    expect(idle.issue).toBeNull();
  });

  test("createIdleMarker returns standard default", () => {
    const idle = createIdleMarker();
    expect(idle.status).toBe("idle");
    expect(idle.target).toBe("compound-engineering-v3.26.3");
  });
});
