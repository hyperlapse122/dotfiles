// An unconsumed prompt stream keeps this query from starting a model turn.
import { createRequire } from 'node:module';

let session;
try {
  const require = createRequire(import.meta.url);
  const { query } = await import(require.resolve('@anthropic-ai/claude-agent-sdk'));
  const controller = new AbortController();
  const prompt = {
    async *[Symbol.asyncIterator]() {
      await new Promise((resolve) => {
        controller.signal.addEventListener('abort', resolve, { once: true });
      });
    },
  };
  session = query({ prompt, options: {
    abortController: controller,
    pathToClaudeCodeExecutable: 'claude',
    settingSources: [],
    mcpServers: {},
    strictMcpConfig: true,
  } });
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const usage = await session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
    process.stdout.write(JSON.stringify(usage) + '\n');
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
} catch {
  process.exitCode = 1;
} finally {
  session?.close();
}
