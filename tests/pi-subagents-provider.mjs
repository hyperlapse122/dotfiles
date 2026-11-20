import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

export default function (pi) {
  pi.registerProvider("subagents-test", {
    baseUrl: "https://example.invalid",
    api: "subagents-test",
    apiKey: "FAKE",
    models: [{ id: "test", name: "Test", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 65536, maxTokens: 4096 }],
    streamSimple(model, { messages }) {
      const stream = createAssistantMessageEventStream();
      const last = messages.at(-1);
      const parent = last?.role === "user" && last.content.some((part) => part.text === "Start the test parent.");
      const content = parent
        ? [{ type: "toolCall", id: "delegate-test", name: "subagent",
          arguments: { agent: "delegate", task: "Return the test child marker.", async: false } }]
        : [{ type: "text", text: last?.role === "toolResult" ? "Parent finished." : "Test child marker." }];
      const message = {
        role: "assistant", content, model: model.id, api: model.api, provider: model.provider,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: parent ? "toolUse" : "stop", timestamp: Date.now(),
      };
      stream.push({ type: "done", reason: message.stopReason, message });
      return stream;
    },
  });
}
