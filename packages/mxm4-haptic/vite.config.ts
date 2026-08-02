import { defineConfig } from "vite-plus";

export default defineConfig({
  // `vp pack` (tsdown) config, inlined from the old tsdown.config.ts.
  pack: {
    entry: ["src/index.ts"],
    format: ["esm"],
    // type:module makes .js mean ESM, so emit dist/index.js + dist/index.d.ts
    // (matching package.json exports) instead of the default .mjs/.d.mts.
    fixedExtension: false,
    dts: true,
    clean: true,
  },
  // `vp run build:omp-plugin` emits the deployable OMP package entry without
  // cleaning the normal library artifact. Local client code is bundled; the
  // resulting module may import only Node built-ins at runtime.
  build: {
    outDir: "dist/omp-plugin",
    emptyOutDir: false,
    lib: {
      entry: "src/omp-plugin.ts",
      formats: ["es"],
      fileName: "index",
    },
    rollupOptions: {
      external: [/^node:/],
    },
  },
  // `vp test` (Vitest) — tests live under test/, importing ../src directly.
  test: {
    include: ["test/**/*.test.ts"],
    // vite-plus/test is `export * from "vitest"`; it must be transformed (not
    // externalized) so the re-exported runner primitives bind to vp test's
    // Vitest instance instead of the raw non-runner entry.
    server: { deps: { inline: ["vite-plus"] } },
  },
  // Workspace tasks: `vp run -r <task>` fans these out in dependency order.
  // `dependsOn ^build` (build every workspace dependency first) is expressed as
  // { task: "build", from: "dependencies" } — a no-op here (no workspace deps).
  run: {
    tasks: {
      build: {
        command: "vp pack && vp build",
        dependsOn: [{ task: "build", from: "dependencies" }],
      },
      "build:omp-plugin": {
        command: "vp build",
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
