
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
  },
};
