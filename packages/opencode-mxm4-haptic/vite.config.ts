import { defineConfig } from "vite-plus";

export default defineConfig({
  // `vp pack` (tsdown) config, inlined from the old tsdown.config.ts.
  // @h82/mxm4-haptic + ts-pattern are bundled into the plugin file;
  // @opencode-ai/plugin is a host-provided peer, never bundled.
  pack: {
    entry: ["./src/index.ts"],
    deps: {
      neverBundle: ["@opencode-ai/plugin"],
      alwaysBundle: ["@h82/mxm4-haptic", "ts-pattern"],
      onlyBundle: false,
    },
    platform: "node",
    target: "esnext",
    format: "esm",
  },
  test: {
    include: ["test/**/*.test.ts"],
    // vite-plus/test is `export * from "vitest"`; it must be transformed (not
    // externalized) so the re-exported runner primitives bind to vp test's
    // Vitest instance instead of the raw non-runner entry.
    server: { deps: { inline: ["vite-plus"] } },
  },
  // `dependsOn ^build` builds @h82/mxm4-haptic (a workspace dependency) before
  // this package's build/typecheck/test, which bundle/consume its dist output.
  run: {
    tasks: {
      build: {
        command: "vp pack",
        dependsOn: [{ task: "build", from: "dependencies" }],
      },
      typecheck: {
        command: "tsc -p tsconfig.json --noEmit",
        dependsOn: [{ task: "build", from: "dependencies" }],
      },
      test: {
        command: "vp test",
        dependsOn: [{ task: "build", from: "dependencies" }],
      },
    },
  },
});
