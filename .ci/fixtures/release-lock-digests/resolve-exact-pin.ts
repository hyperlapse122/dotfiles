import { runCli } from "../../../packages/release-lock/src/cli.ts";
import { resolveAll } from "../../../packages/release-lock/src/resolve-all.ts";
import type { Registry } from "../../../packages/release-lock/src/types.ts";

const registry: Registry = {
  pinned: {
    kind: "githubRelease",
    source: "owner/pinned",
    exactTag: "1.1.28",
    asset: ({ os, arch }) => (os === "linux" && arch === "amd64" ? "tool" : null),
  },
};

for (const [name, digest] of [
  ["absent", null],
  ["malformed", "sha256:nothex"],
] as const) {
  globalThis.fetch = async () =>
    Response.json({
      tag_name: "1.1.28",
      assets: [
        { name: "tool", browser_download_url: "https://example.invalid/1.1.28/tool", digest },
      ],
    });
  const code = await runCli(["--out", `${process.argv[2]}/${name}.json`], {
    resolve: () => resolveAll(undefined, registry),
  });
  if (code !== 0) throw new Error(`fixture resolution failed: ${name}`);
}
