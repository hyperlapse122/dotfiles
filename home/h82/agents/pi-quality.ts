
const edits = new Set(["edit", "write"]);

export default function quality(pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash" && !edits.has(event.toolName)) return;
    const reason = await check("pre", ctx.cwd, event.toolName, event.input);
    if (reason) return { block: true, reason };
  });
}
