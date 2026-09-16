import { defineConfig } from "vite-plus";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    server: { deps: { inline: ["vite-plus"] } },
  },
  run: {
    tasks: {
      build: {
        // DOTFILES_HOOK_BUILD_ID is baked in with --define rather than read at
        // runtime: the deployed binary runs with an empty environment, so a
        // runtime process.env read would always be empty. The build script
        // computes the id from the same sources the fingerprint covers, which
        // is what makes `--version` answer "did my edit reach this host".
        command:
          "bun build --compile --define process.env.DOTFILES_HOOK_BUILD_ID=\"'$DOTFILES_HOOK_BUILD_ID'\" ./src/cli.ts --outfile ./dist/orchestration-hook",
        // One build input lives outside this workspace root and out of reach of
        // any `input` base: the locked bun version in .chezmoidata/releases.json,
        // because the compiled binary embeds a bun runtime. The build script
        // exports a digest of it so it enters the cache key here. Without this,
        // `bun build --compile` runs as an external process whose reads
        // automatic tracking cannot see. The payload bodies are no longer build
        // inputs at all — the binary reads them as managed files at run time.
        env: ["DOTFILES_BUN_VERSION", "DOTFILES_HOOK_BUILD_ID"],
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
