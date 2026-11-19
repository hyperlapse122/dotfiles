import { readFileSync, writeFileSync, mkdtempSync, copyFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const temporary = mkdtempSync(join(tmpdir(), 'pi-policy-'));
try {
  // Copy only the files the policy reads. Copying the whole agent tree keeps
  // the store's read-only directory modes, which the cleanup cannot remove.
  for (const name of ['dotfiles-policy.ts', 'model-lock.json', 'models.json'])
    copyFileSync(join(process.argv[2], name), join(temporary, name));
  const policy = readFileSync(join(temporary, 'dotfiles-policy.ts'), 'utf8');
  writeFileSync(join(temporary, 'policy.mjs'), policy);
  const { default: install } = await import(pathToFileURL(join(temporary, 'policy.mjs')));
  const hooks = {};
  install({ on: (event, fn) => hooks[event] = fn });
  const lock = JSON.parse(readFileSync(join(temporary, 'model-lock.json'), 'utf8'));
  const synthetic = lock.syntheticModelLocks.models.map(model => ({provider: 'synthetic', id: model.id}));
  const openai = lock.openaiModelLocks.models.map(model => ({provider: 'openai', id: model.id}));
  const anthropic = lock.anthropicModelLocks.models.map(model => ({provider: 'anthropic', id: model.id}));
  assert(openai.length && anthropic.length, 'the combined lock names no OpenAI or Anthropic model');

  async function discover(registry, model) {
    let stopped = false;
    process.exitCode = 0;
    await hooks.resources_discover({}, { model, shutdown: () => stopped = true,
      modelRegistry: { refresh: async () => {}, getAll: () => registry } });
    process.exitCode = 0;
    return stopped;
  }
  const locked = [...synthetic, openai[0], anthropic[0]];
  for (const model of [synthetic[0], openai[0], anthropic[0]])
    assert.equal(await discover(locked, model), false, `${model.provider}/${model.id} must be accepted`);
  for (const model of [{provider: 'foreign', id: 'outside'}, {provider: 'synthetic', id: 'outside'},
                       {provider: 'openai', id: 'outside'}, {provider: 'anthropic', id: 'outside'}])
    assert.equal(await discover(locked, model), true, `${model.provider}/${model.id} must be refused`);

  assert.equal(await discover(synthetic, synthetic[0]), false);
  assert.equal(await discover(synthetic.slice(1), undefined), true);
  assert.equal(await discover([...locked, {provider: 'openai', id: 'outside'}], undefined), true);
  assert.equal(await discover([...locked, {provider: 'foreign', id: 'outside'}], undefined), true);

  async function restore(provider, modelId) {
    let stopped = false;
    hooks.session_start({}, {shutdown: () => stopped = true,
      sessionManager: {getBranch: () => [{type: 'model_change', provider, modelId}, {type: 'message'}]}});
    process.exitCode = 0;
    return stopped;
  }
  assert.equal(await restore('foreign', 'outside'), true);
  assert.equal(await restore('openai', 'outside'), true);
  assert.equal(await restore('anthropic', 'outside'), true);
  assert.equal(await restore('openai', openai[0].id), false);
  assert.equal(await restore('anthropic', anthropic[0].id), false);
  assert.equal(await restore('synthetic', synthetic[0].id), false);
} finally { rmSync(temporary, { recursive: true, force: true }); }
