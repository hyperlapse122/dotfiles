import { defineConfig } from "vite-plus";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    server: { deps: { inline: ["vite-plus"] } },
  },
  run: {
    tasks: {
      build: {
        command: "bun build --compile ./src/cli.ts --outfile ./dist/command-reconcile",
        // The compiled binary embeds a bun runtime, but the locked bun version
        // lives in .chezmoidata/releases.json, outside this workspace root and
        // out of reach of any `input` base. The build scripts export it as
        // DOTFILES_BUN_VERSION so it can enter the cache key here instead.
        env: ["DOTFILES_BUN_VERSION"],
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
      typecheck: { command: "tsc -p tsconfig.json --noEmit" },
      test: { command: "vp test" },
    },
  },
});
