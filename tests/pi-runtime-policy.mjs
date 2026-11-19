import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const temporary = mkdtempSync(join(tmpdir(), 'pi-runtime-policy-'));
const previousAgent = process.env.PI_CODING_AGENT_DIR;
const previousOffline = process.env.PI_OFFLINE;
const realFetch = globalThis.fetch;
process.env.PI_CODING_AGENT_DIR = temporary;
process.env.PI_OFFLINE = '1';
try {
  const launcher = realpathSync(join(process.argv[2], 'libexec/pi/pi'));
  const modules = join(dirname(dirname(launcher)), 'lib/pi/node_modules');
  const coreOf = root => join(root, '@earendil-works/pi-coding-agent/dist/core');
  const real = JSON.parse(readFileSync(join(process.argv[3], 'model-lock.json'), 'utf8'));

  // The compiled lock is the combined lock the home files carry.
  const compiled = readFileSync(join(coreOf(modules), 'dotfiles-model-lock.js'), 'utf8');
  assert.deepEqual(JSON.parse(compiled.slice(compiled.indexOf('{'), compiled.lastIndexOf('};') + 1)), real);

  // A copy of the installed packages whose lock is a small fixed one, so the
  // expectations do not move when a snapshot refresh changes the real lock.
  const copy = join(temporary, 'node_modules');
  mkdirSync(join(copy, '@earendil-works'), {recursive: true});
  for (const name of readdirSync(modules)) {
    if (name !== '@earendil-works') symlinkSync(join(modules, name), join(copy, name));
  }
  for (const name of readdirSync(join(modules, '@earendil-works'))) {
    const from = join(modules, '@earendil-works', name);
    const to = join(copy, '@earendil-works', name);
    if (name === 'pi-coding-agent') cpSync(realpathSync(from), to, {recursive: true});
    else symlinkSync(realpathSync(from), to);
  }
  // The copy keeps the store's read-only modes, so make it writable before replacing the lock.
  execFileSync('chmod', ['-R', 'u+w', copy]);
  const synthetic = real.syntheticModelLocks;
  const fixture = {
    syntheticModelLocks: synthetic,
    openaiModelLocks: {provider: 'openai', models: [{id: 'gpt-5.5'}, {id: 'gpt-6-luna'}, {id: 'unknown-to-pi'}]},
    anthropicModelLocks: {provider: 'anthropic', models: [{id: 'claude-opus-5-5'}, {id: 'claude-fable-5'}]},
  };
  writeFileSync(join(coreOf(copy), 'dotfiles-model-lock.js'), 'export default ' + JSON.stringify(fixture) + ';\n');
  const { ModelRuntime } = await import(pathToFileURL(join(coreOf(copy), 'model-runtime.js')));

  const auth = join(temporary, 'auth.json');
  writeFileSync(auth, JSON.stringify(Object.fromEntries(['synthetic', 'openai', 'anthropic', 'google']
    .map(provider => [provider, {type: 'api_key', key: 'FAKE'}]))));
  const runtime = await ModelRuntime.create({modelsPath: null, authPath: auth, allowModelNetwork: false});
  const expected = [
    ...synthetic.models.map(model => `synthetic/${model.id}`),
    'openai/gpt-5.5', 'openai/gpt-6-luna', 'anthropic/claude-opus-5-5', 'anthropic/claude-fable-5',
  ].sort();
  const identities = models => models.map(model => `${model.provider}/${model.id}`).sort();
  const everything = async candidate => {
    assert.deepEqual(identities(candidate.getModels()), expected);
    assert.deepEqual(identities(candidate.getAllModels()), expected);
    assert.deepEqual(identities(await candidate.getAvailable()), expected);
    assert.deepEqual(identities(await candidate.getAllAvailable()), expected);
  };
  await everything(runtime);
  // gpt-6-luna names a chat model and a classifier model; only the chat model is offered.
  assert.equal(runtime.getAllModels('openai').filter(model => model.id === 'gpt-6-luna').length, 1);
  assert.equal(runtime.getModel('openai', 'gpt-6-luna').api, 'openai-responses');
  assert.equal(runtime.getModel('openai', 'gpt-4'), undefined, 'a built-in model outside the lock is offered');
  assert.equal(runtime.getModel('openai', 'unknown-to-pi'), undefined);
  assert.equal(runtime.getModel('google', 'gemini-2.5-pro'), undefined);
  // The lock governs what Pi offers; Anthropic's own fallback list stays on the model.
  const fallbacks = runtime.getModel('anthropic', 'claude-fable-5').compat.allowedFallbackModels.map(entry => entry.model);
  assert(fallbacks.length > 0 && fallbacks.some(id => !fixture.anthropicModelLocks.models.some(model => model.id === id)), fallbacks);

  const original = {
    openai: runtime.getModel('openai', 'gpt-5.5'),
    anthropic: runtime.getModel('anthropic', 'claude-opus-5-5'),
  };
  const extra = {...synthetic.models[0], id: 'outside'};
  runtime.registerProvider('foreign', {...synthetic, models: [extra]});
  runtime.registerProvider('synthetic', {...synthetic, baseUrl: 'https://wrong.invalid', models: [extra]});
  runtime.registerProvider('openai', {...synthetic, baseUrl: 'https://wrong.invalid', models: [extra]});
  runtime.registerNativeProvider({...runtime.getProvider('anthropic'), baseUrl: 'https://wrong.invalid', getModels: () => [extra]});
  runtime.registerNativeProvider({...runtime.getProvider('synthetic'), baseUrl: 'https://wrong.invalid', getModels: () => [extra]});
  runtime.registerVirtualModel({provider: 'foreign', id: 'virtual', name: 'Virtual',
    route: async () => ({model: {provider: 'foreign', id: 'outside'}, thinkingLevel: 'off'})});
  runtime.registerVirtualModel({provider: 'openai', id: 'virtual', name: 'Virtual',
    route: async () => ({model: {provider: 'openai', id: 'gpt-4'}, thinkingLevel: 'off'})});
  await runtime.refresh({allowNetwork: false});
  await everything(runtime);
  assert.deepEqual(runtime.getModel('openai', 'gpt-5.5'), original.openai);
  assert.deepEqual(runtime.getModel('anthropic', 'claude-opus-5-5'), original.anthropic);
  assert.equal(runtime.getModel('foreign', 'outside'), undefined);
  assert.equal(runtime.getPhysicalModel('foreign', 'virtual'), undefined);
  assert.equal(runtime.getPhysicalModel('openai', 'virtual'), undefined);

  // models.json cannot add to or redefine a locked provider.
  const overlay = join(temporary, 'models.json');
  writeFileSync(overlay, JSON.stringify({providers: {
    openai: {baseUrl: 'https://wrong.invalid', models: [{id: 'overlay-model', name: 'Overlay'}],
             modelOverrides: {'gpt-5.5': {cost: {input: 0}}}},
    anthropic: {models: [{id: 'overlay-model', name: 'Overlay'}]},
    google: {models: [{id: 'overlay-model', name: 'Overlay'}]},
  }}));
  const overlaid = await ModelRuntime.create({modelsPath: overlay, authPath: auth, allowModelNetwork: false});
  await everything(overlaid);
  assert.deepEqual(overlaid.getModel('openai', 'gpt-5.5'), original.openai);

  // Starting with network refresh allowed asks neither pi.dev nor a provider for a model list.
  const urls = [];
  globalThis.fetch = async input => { urls.push(String(input)); throw new Error('no network'); };
  delete process.env.PI_OFFLINE;
  const online = await ModelRuntime.create({modelsPath: null, authPath: auth, allowModelNetwork: true});
  await online.refresh({allowNetwork: true, force: true});
  await everything(online);
  assert.deepEqual(urls, []);
  globalThis.fetch = realFetch;
  process.env.PI_OFFLINE = '1';

  const requested = [];
  const fetch = async (input, init) => {
    requested.push(String(input));
    return new Response('{"error":{"message":"probe"}}', {status: 500, headers: {'content-type': 'application/json'}});
  };
  const context = {messages: [{role: 'user', content: 'probe', timestamp: 0}]};
  const rejected = await runtime.streamSimple({...original.openai, id: 'gpt-4'}, context, {fetch}).result();
  assert.equal(rejected.stopReason, 'error');
  assert.match(rejected.errorMessage, /managed model lock/);
  const unknown = await runtime.streamSimple({...original.anthropic, id: 'claude-not-locked'}, context, {fetch}).result();
  assert.match(unknown.errorMessage, /managed model lock/);
  assert.deepEqual(requested, []);
  await runtime.streamSimple({...original.openai, baseUrl: 'https://wrong.invalid'}, context, {fetch}).result();
  await runtime.streamSimple({...original.anthropic, baseUrl: 'https://wrong.invalid'}, context, {fetch}).result();
  assert(requested.length >= 2, requested);
  assert(requested.every(url => !url.includes('wrong.invalid')), requested);
  assert(requested.some(url => url.startsWith(original.openai.baseUrl)), requested);
  assert(requested.some(url => url.startsWith(original.anthropic.baseUrl)), requested);

  // Synthetic still routes to its locked chat-completions endpoint.
  const sse = 'data: {"id":"probe","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}\n\n'
    + 'data: {"id":"probe","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
  const syntheticUrls = [];
  const syntheticFetch = async input => {
    syntheticUrls.push(String(input));
    return new Response(sse, {headers: {'content-type': 'text/event-stream'}});
  };
  const model = runtime.getModels().find(entry => entry.provider === 'synthetic');
  const accepted = await runtime.streamSimple({...model, baseUrl: 'https://wrong.invalid'}, context, {fetch: syntheticFetch}).result();
  assert.equal(accepted.stopReason, 'stop', accepted.errorMessage);
  assert.deepEqual(syntheticUrls, [synthetic.baseUrl + '/chat/completions']);
} finally {
  globalThis.fetch = realFetch;
  if (previousAgent === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgent;
  if (previousOffline === undefined) delete process.env.PI_OFFLINE;
  else process.env.PI_OFFLINE = previousOffline;
  rmSync(temporary, {recursive: true, force: true});
}
