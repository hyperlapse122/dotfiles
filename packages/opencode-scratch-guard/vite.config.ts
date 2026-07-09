import { defineConfig } from "vite-plus";

export default defineConfig({
  // `vp pack` (tsdown) config, inlined from the old tsdown.config.ts.
  // @opencode-ai/plugin is a host-provided peer, never bundled; the plugin has
  // no other runtime deps (only Node builtins).
  pack: {
    entry: ["./src/index.ts"],
    deps: {
      neverBundle: ["@opencode-ai/plugin"],
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
