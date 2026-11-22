
const edits = new Set(["edit", "write", "patch"]);

export default {
  id: "dotfiles-agent-quality",
  async setup(ctx) {
    const cwd = ctx.location.directory;
    await ctx.tool.hook("execute.before", async (event) => {
      if (event.tool !== "shell" && !edits.has(event.tool)) return;
      const reason = await check("pre", cwd, event.tool, event.input);
      if (reason) throw new Error(reason);
    });
    await ctx.tool.hook("execute.after", async (event) => {
      if (event.status !== "completed" || !edits.has(event.tool)) return;
      const text = await check("post", cwd, event.tool, event.input);
      if (text) {
        const { content } = event.result;
        const prior = typeof content === "string" ? [{ type: "text", text: content }] : (content ?? []);
        event.result = { ...event.result, content: [...prior, { type: "text", text }] };
      }
    });

    if (!stop) return;
    // OpenCode admits synthetic input directly to the inbox. Only a prompt
    // goes through SessionPrompt.prepare and arms this idle hook again.
    const pending = new Set();
    await ctx.session.hook("prompt", (event) => {
      pending.add(event.sessionID);
    });
    await ctx.session.hook("experimental.idle", async (event) => {
      if (!pending.delete(event.sessionID)) return;
      const text = await check("stop", cwd);
      if (text) await ctx.session.synthetic({ sessionID: event.sessionID, text });
    });
  },
};
