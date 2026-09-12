import { describe, expect, it } from "vite-plus/test";
import {
  composeContext,
  emptyOutput,
  leadContext,
  PREAMBLE,
  deliveryEnvelope,
  sessionStartEnvelope,
  workerContext,
  isHarness,
} from "../src/envelope.js";
import { payload } from "../src/payload.js";

const parts = { skill: "SKILL BODY", guide: "GUIDE BODY" };

describe("workerContext", () => {
  it("is the preamble followed by the everyone payload", () => {
    const text = workerContext();
    expect(text.startsWith(PREAMBLE)).toBe(true);
    expect(text).toContain(payload("everyone"));
  });

  it("carries no coordinator rules", () => {
    expect(workerContext()).not.toContain(payload("coordinator"));
  });
});

describe("leadContext", () => {
  it("orders preamble, skill, guide, everyone, coordinator", () => {
    const text = leadContext(parts);
    if (text === null) throw new Error("expected a lead envelope");
    const order = [
      text.indexOf(PREAMBLE),
      text.indexOf(parts.skill),
      text.indexOf(parts.guide),
      text.indexOf(payload("everyone")),
      text.indexOf(payload("coordinator")),
    ];
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  it("delivers nothing when the guide half is missing", () => {
    expect(leadContext({ skill: "SKILL BODY", guide: "" })).toBeNull();
  });

  it("delivers nothing when the skill half is missing", () => {
    expect(leadContext({ skill: "", guide: "GUIDE BODY" })).toBeNull();
  });
});

describe("composeContext", () => {
  it("delivers nothing to a session outside Orca", () => {
    expect(composeContext("claude", "none", () => parts)).toBeNull();
    expect(composeContext("codex", "none", () => parts)).toBeNull();
  });

  it("gives a Claude Code lead the lead envelope", () => {
    const text = composeContext("claude", "lead", () => parts);
    expect(text).toContain(payload("coordinator"));
  });

  it("gives a Claude Code worker the everyone envelope only", () => {
    const text = composeContext("claude", "worker", () => parts);
    expect(text).not.toContain(payload("coordinator"));
    expect(text).toContain(payload("everyone"));
  });

  it("gives a Codex worker the everyone envelope only", () => {
    const text = composeContext("codex", "worker", () => parts);
    expect(text).not.toContain(payload("coordinator"));
    expect(text).toContain(payload("everyone"));
  });

  it("never calls Orca for a worker", () => {
    let called = false;
    composeContext("claude", "worker", () => {
      called = true;
      return parts;
    });
    expect(called).toBe(false);
  });

  it("delivers nothing when a Claude Code lead cannot get its guide", () => {
    expect(composeContext("claude", "lead", () => null)).toBeNull();
  });
});

describe("additional harness roles", () => {
  it("gives agy a complete lead envelope in order", () => {
    const text = composeContext("agy", "lead", () => parts);
    if (text === null) throw new Error("expected a lead envelope");
    const order = [
      text.indexOf(PREAMBLE),
      text.indexOf(parts.skill),
      text.indexOf(parts.guide),
      text.indexOf(payload("everyone")),
      text.indexOf(payload("coordinator")),
    ];
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  it("gives agy workers the everyone envelope only", () => {
    const text = composeContext("agy", "worker", () => parts);
    expect(text).toContain(PREAMBLE);
    expect(text).toContain(payload("everyone"));
    expect(text).not.toContain(payload("coordinator"));
  });

  it("gives agy none roles a parseable no-op", () => {
    expect(composeContext("agy", "none", () => parts)).toBeNull();
    expect(() => JSON.parse(emptyOutput("agy"))).not.toThrow();
  });

  it("does not deliver a half envelope to an agy lead", () => {
    expect(composeContext("agy", "lead", () => ({ skill: "", guide: parts.guide }))).toBeNull();
    expect(composeContext("agy", "lead", () => ({ skill: parts.skill, guide: "" }))).toBeNull();
  });

  it("gives a codex lead the lead envelope", () => {
    const text = composeContext("codex", "lead", () => parts);
    expect(text).toContain(payload("coordinator"));
  });

  it("accepts agy and rejects the unmanaged harness", () => {
    expect(isHarness("agy")).toBe(true);
    expect(isHarness("omp")).toBe(false);
  });
});

describe("output shape", () => {
  it("wraps context in the SessionStart envelope", () => {
    const parsed = JSON.parse(sessionStartEnvelope("BODY")) as {
      hookSpecificOutput: { hookEventName: string; additionalContext: string };
    };
    expect(parsed.hookSpecificOutput.hookEventName).toBe("SessionStart");
    expect(parsed.hookSpecificOutput.additionalContext).toBe("BODY");
  });

  it("gives a document to the harnesses that parse one, and Codex nothing at all", () => {
    expect(emptyOutput("claude")).toBe("{}");
    expect(emptyOutput("agy")).toBe("{}");
    expect(emptyOutput("codex")).toBe("");
  });

  it("keeps the SessionStart shape for the harnesses that have that event", () => {
    for (const harness of ["claude", "codex"] as const) {
      expect(deliveryEnvelope(harness, "BODY")).toBe(sessionStartEnvelope("BODY"));
    }
  });

  it("delivers the whole envelope to Antigravity as one ephemeral step", () => {
    const parsed = JSON.parse(deliveryEnvelope("agy", "BODY")) as {
      injectSteps: { ephemeralMessage?: string }[];
    };
    expect(parsed.injectSteps).toHaveLength(1);
    expect(parsed.injectSteps[0]?.ephemeralMessage).toBe("BODY");
  });
});
