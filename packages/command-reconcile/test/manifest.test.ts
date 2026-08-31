import { describe, expect, it } from "vite-plus/test";
import { parseManifest } from "../src/manifest.js";

describe("parseManifest", () => {
  it("parses valid manifest", () => {
    const json = JSON.stringify({
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "omp",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "omp" }],
          identity: "v0.35.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/omp",
        },
      ],
    });
    const manifest = parseManifest(json);
    expect(manifest.schemaVersion).toBe("command-manifest/v1");
    expect(manifest.units.length).toBe(1);
    expect(manifest.units[0]?.id).toBe("omp");
    expect(manifest.units[0]?.proofEligible).toBe(true);
  });

  it("throws on invalid schema version", () => {
    const json = JSON.stringify({
      schemaVersion: "command-manifest/v2",
      units: [],
    });
    expect(() => parseManifest(json)).toThrow("Unsupported manifest schema version");
  });

  it("throws on unknown producer", () => {
    const json = JSON.stringify({
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "foo",
          producer: "invalid",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "foo" }],
          identity: "1.0",
          stagingPath: "path",
        },
      ],
    });
    expect(() => parseManifest(json)).toThrow("invalid producer");
  });
});
