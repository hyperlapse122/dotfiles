import { defineConfig } from "vite-plus";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    server: { deps: { inline: ["vite-plus"] } },
  },
  run: {
    tasks: {
      build: {
        command: "bun build --compile ./src/index.ts --outfile ./dist/figma-auth",
        dependsOn: [{ task: "build", from: "dependencies" }],
        // Explicit inputs: auto file tracking misses reads by the external
        // bun process, so source edits would replay a stale cached build.
        input: [
          "src/**",
          "package.json",
          "tsconfig.json",
          "vite.config.ts",
          { pattern: "package.json", base: "workspace" },
          { pattern: "bun.lock", base: "workspace" },
          { pattern: "bunfig.toml", base: "workspace" },
          { pattern: "vite.config.ts", base: "workspace" },
        ],
        output: ["dist/**"],
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
