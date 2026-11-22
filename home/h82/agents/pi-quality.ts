
const edits = new Set(["edit", "write"]);

export default function quality(pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash" && !edits.has(event.toolName)) return;
    const reason = await check("pre", ctx.cwd, event.toolName, event.input);
    if (reason) return { block: true, reason };
  });
  pi.on("tool_result", async (event, ctx) => {
    if (event.isError || !edits.has(event.toolName)) return;
    const text = await check("post", ctx.cwd, event.toolName, event.input);
    if (text) return { content: [...event.content, { type: "text", text }] };
  });

  if (!stop) return;
  let retried = false;
  pi.on("before_agent_start", () => {
    retried = false;
  });
  pi.on("agent_before_settle", async (event, ctx) => {
    if (retried || event.outcome !== "completed") return;
    const content = await check("stop", ctx.cwd);
    if (!content) return;
    retried = true;
    return {
      entries: [...event.entries, { type: "custom_message", customType: "agent-check", content, display: true }],
      continue: true,
    };
  });
}
