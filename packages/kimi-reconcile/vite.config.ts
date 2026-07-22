import { defineConfig } from "vite-plus";

export default defineConfig({
  test: { include: ["test/**/*.test.ts"], server: { deps: { inline: ["vite-plus"] } } },
  run: {
    tasks: {
      build: { command: "bun build --compile ./src/cli.ts --outfile ./dist/kimi-reconcile" },
      typecheck: { command: "tsc -p tsconfig.json --noEmit" },
      test: { command: "vp test" },
    },
  },
});
