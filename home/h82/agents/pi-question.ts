import { Type } from "typebox";

export default function (pi) {
  pi.registerTool({
    name: "question", label: "Question",
    description: "Ask the user one question, with optional choices or a typed answer. Cancellation and unavailable UI are not answers.",
    promptSnippet: "Ask the user a question through a native dialog.",
    executionMode: "sequential",
    parameters: Type.Object({ question: Type.String({ minLength: 1 }),
      options: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { maxItems: 10, uniqueItems: true })) }),
    async execute(_id, { question, options = [] }, signal, _update, ctx) {
      const finish = (status, answer = null) => ({
        content: [{ type: "text", text: JSON.stringify({ status, question, answer }) }],
        details: { status, question, answer },
      });
      if (signal?.aborted) return finish("cancelled");
      if (!ctx.hasUI) return finish("ui_unavailable");
      let answer;
      if (options.length) {
        let typed = "Type an answer…";
        while (options.includes(typed)) typed += "…";
        answer = await ctx.ui.select(question, [...options, typed], { signal });
        if (answer === typed && !signal?.aborted)
          answer = await ctx.ui.input(question, "Your answer", { signal });
      } else {
        answer = await ctx.ui.input(question, "Your answer", { signal });
      }
      if (signal?.aborted || answer === undefined) return finish("cancelled");
      return answer.trim() ? finish("answered", answer) : finish("empty");
    },
  });
}
