import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vite-plus/test";
import { fetchGuide, resolveOrcaCommand } from "../src/orca.js";

describe("resolveOrcaCommand", () => {
  it("remaps the bare name on a non-Darwin host", () => {
    // /usr/bin/orca is the GNOME screen reader there; running it would start
    // speech in the user's session.
    expect(resolveOrcaCommand({ configured: "orca", platform: "Linux" })).toBe("orca-ide");
  });

  it("remaps the absolute screen-reader path on a non-Darwin host", () => {
    expect(resolveOrcaCommand({ configured: "/usr/bin/orca", platform: "Linux" })).toBe("orca-ide");
  });

  it("remaps when the platform could not be read", () => {
    expect(resolveOrcaCommand({ configured: "orca" })).toBe("orca-ide");
  });

  it("honours the bare name on a confirmed Darwin", () => {
    expect(resolveOrcaCommand({ configured: "orca", platform: "Darwin" })).toBe("orca");
  });

  it("falls back to the safe CLI when nothing is configured", () => {
    expect(resolveOrcaCommand({ platform: "Darwin" })).toBe("orca-ide");
  });

  it("leaves an unrelated configured command alone", () => {
    expect(resolveOrcaCommand({ configured: "orca-dev", platform: "Linux" })).toBe("orca-dev");
  });
});

describe("fetchGuide", () => {
  let dir: string;
  const stub = (name: string, body: string) => {
    const path = join(dir, name);
    writeFileSync(path, `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(path, 0o755);
    return path;
  };

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "orchestration-hook-orca-"));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns the guide a healthy CLI prints", async () => {
    const cli = stub("cli-ok", 'printf "GUIDE BODY\\n"');
    const { guide } = await fetchGuide({ command: cli, deadlineMs: 5_000 });
    expect(guide).toContain("GUIDE BODY");
  });

  it("returns null when the CLI exits non-zero", async () => {
    const cli = stub("cli-fail", 'printf "partial\\n"; exit 3');
    expect((await fetchGuide({ command: cli, deadlineMs: 5_000 })).guide).toBeNull();
  });

  it("returns null when the CLI succeeds with empty output", async () => {
    const cli = stub("cli-empty", "exit 0");
    expect((await fetchGuide({ command: cli, deadlineMs: 5_000 })).guide).toBeNull();
  });

  it("returns null when the command does not exist", async () => {
    const { guide } = await fetchGuide({
      command: join(dir, "not-installed"),
      deadlineMs: 5_000,
    });
    expect(guide).toBeNull();
  });

  it("returns null when the deadline has already passed", async () => {
    const cli = stub("cli-unused", 'printf "GUIDE\\n"');
    expect((await fetchGuide({ command: cli, deadlineMs: 0 })).guide).toBeNull();
  });

  it("gives up at the deadline rather than waiting for a hanging CLI", async () => {
    const cli = stub("cli-hang", "sleep 30");
    const started = Date.now();
    const { guide } = await fetchGuide({ command: cli, deadlineMs: 300 });
    expect(guide).toBeNull();
    expect(Date.now() - started).toBeLessThan(3_000);
  });

  it("does not let a descendant outlive the deadline holding the pipe", async () => {
    // The real CLI is a launcher whose child holds the pipe. Signalling the
    // direct child alone leaves that descendant alive and the stream open.
    const cli = stub("cli-launcher", "sleep 30 & wait");
    const started = Date.now();
    const { guide } = await fetchGuide({ command: cli, deadlineMs: 300 });
    expect(guide).toBeNull();
    expect(Date.now() - started).toBeLessThan(3_000);
  });
});
