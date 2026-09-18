import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import {
  composeContext,
  emptyOutput,
  LEAD_INTRO,
  leadContext,
  PREAMBLE,
  deliveryEnvelope,
  sessionStartEnvelope,
  workerContext,
  isHarness,
} from "../src/envelope.js";

// The bodies are managed files the deployed binary reads at run time, so the
// tests read files too — a fixture pair, not the real targets, so a case cannot
// depend on whatever this host last applied.
const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "payload");
const env = { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: FIXTURES };
const EVERYONE = readFileSync(join(FIXTURES, "everyone.md"), "utf8");
const COORDINATOR = readFileSync(join(FIXTURES, "coordinator.md"), "utf8");
const MISSING = { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: join(FIXTURES, "absent") };

const parts = { skill: "SKILL BODY", guide: "GUIDE BODY" };

describe("workerContext", () => {
  it("is the preamble followed by the everyone payload", () => {
    const text = workerContext(env);
    if (text === null) throw new Error("expected a worker envelope");
    expect(text.startsWith(PREAMBLE)).toBe(true);
    expect(text).toContain(EVERYONE);
  });

  it("carries no coordinator rules", () => {
    expect(workerContext(env)).not.toContain(COORDINATOR);
  });

  it("does not carry the lead's skill re-entry instruction", () => {
    expect(workerContext(env)).not.toContain("Before each dispatch");
  });

  it("delivers nothing when the everyone file is absent", () => {
    expect(workerContext(MISSING)).toBeNull();
  });
});

describe("leadContext", () => {
  it("orders preamble, skill, guide, everyone, coordinator", () => {
    const text = leadContext(parts, env);
    if (text === null) throw new Error("expected a lead envelope");
    const order = [
      text.indexOf(PREAMBLE),
      text.indexOf(parts.skill),
      text.indexOf(parts.guide),
      text.indexOf(EVERYONE),
      text.indexOf(COORDINATOR),
    ];
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  it("opens with the skill re-entry instruction directly after the preamble", () => {
    const text = leadContext(parts, env);
    if (text === null) throw new Error("expected a lead envelope");
    const preambleEnd = PREAMBLE.length;
    expect(text.indexOf(LEAD_INTRO)).toBeGreaterThan(preambleEnd - 1);
    expect(text.slice(preambleEnd, text.indexOf(LEAD_INTRO))).toBe("\n\n");
  });

  it("delivers nothing when the guide half is missing", () => {
    expect(leadContext({ skill: "SKILL BODY", guide: "" }, env)).toBeNull();
  });

  it("delivers nothing when the skill half is missing", () => {
    expect(leadContext({ skill: "", guide: "GUIDE BODY" }, env)).toBeNull();
  });

  it("delivers nothing when a payload file is missing", () => {
    expect(leadContext(parts, MISSING)).toBeNull();
  });
});

describe("composeContext", () => {
  it("delivers nothing to a session outside Orca", () => {
    expect(composeContext("claude", "none", () => parts, env)).toBeNull();
    expect(composeContext("codex", "none", () => parts, env)).toBeNull();
  });

  it("gives a Claude Code lead the lead envelope", () => {
    const text = composeContext("claude", "lead", () => parts, env);
    expect(text).toContain(COORDINATOR);
  });

  it("gives a Claude Code worker the everyone envelope only", () => {
    const text = composeContext("claude", "worker", () => parts, env);
    expect(text).not.toContain(COORDINATOR);
    expect(text).toContain(EVERYONE);
  });

  it("gives a Codex worker the everyone envelope only", () => {
    const text = composeContext("codex", "worker", () => parts, env);
    expect(text).not.toContain(COORDINATOR);
    expect(text).toContain(EVERYONE);
  });

  it("never calls Orca for a worker", () => {
    let called = false;
    composeContext(
      "claude",
      "worker",
      () => {
        called = true;
        return parts;
      },
      env,
    );
    expect(called).toBe(false);
  });

  it("delivers nothing when a Claude Code lead cannot get its guide", () => {
    expect(composeContext("claude", "lead", () => null, env)).toBeNull();
  });
});

describe("additional harness roles", () => {
  it("gives omp a complete lead envelope in order", () => {
    const text = composeContext("omp", "lead", () => parts, env);
    if (text === null) throw new Error("expected a lead envelope");
    const order = [
      text.indexOf(PREAMBLE),
      text.indexOf(parts.skill),
      text.indexOf(parts.guide),
      text.indexOf(EVERYONE),
      text.indexOf(COORDINATOR),
    ];
    expect(order.every((i) => i >= 0)).toBe(true);
    expect([...order].sort((a, b) => a - b)).toEqual(order);
  });

  it("gives omp workers the everyone envelope only", () => {
    const text = composeContext("omp", "worker", () => parts, env);
    expect(text).toContain(PREAMBLE);
    expect(text).toContain(EVERYONE);
    expect(text).not.toContain(COORDINATOR);
  });

  it("gives omp none roles no output", () => {
    expect(composeContext("omp", "none", () => parts, env)).toBeNull();
    expect(emptyOutput("omp")).toBe("");
  });

  it("does not deliver a half envelope to an omp lead", () => {
    expect(
      composeContext("omp", "lead", () => ({ skill: "", guide: parts.guide }), env),
    ).toBeNull();
    expect(
      composeContext("omp", "lead", () => ({ skill: parts.skill, guide: "" }), env),
    ).toBeNull();
  });

  it("gives a codex lead the lead envelope", () => {
    const text = composeContext("codex", "lead", () => parts, env);
    expect(text).toContain(COORDINATOR);
  });

  it("accepts omp and rejects the retired harness", () => {
    expect(isHarness("omp")).toBe(true);
    expect(isHarness("agy")).toBe(false);
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
    expect(emptyOutput("omp")).toBe("");
    expect(emptyOutput("codex")).toBe("");
  });

  it("keeps the SessionStart shape for the harnesses that have that event", () => {
    for (const harness of ["claude", "codex"] as const) {
      expect(deliveryEnvelope(harness, "BODY")).toBe(sessionStartEnvelope("BODY"));
    }
  });

  it("delivers plain context to omp", () => {
    expect(deliveryEnvelope("omp", "BODY")).toBe("BODY");
  });
});
