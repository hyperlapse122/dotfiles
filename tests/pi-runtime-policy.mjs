import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const temporary = mkdtempSync(join(tmpdir(), 'pi-runtime-policy-'));
const previousAgent = process.env.PI_CODING_AGENT_DIR;
process.env.PI_CODING_AGENT_DIR = temporary;
process.env.PI_OFFLINE = '1';
try {
  const launcher = realpathSync(join(process.argv[2], 'libexec/pi/pi'));
  const module = join(dirname(dirname(launcher)),
    'lib/pi/node_modules/@earendil-works/pi-coding-agent/dist/core/model-runtime.js');
  const { ModelRuntime } = await import(pathToFileURL(module));
  const lock = JSON.parse(readFileSync(join(process.argv[3], 'model-lock.json'), 'utf8')).syntheticModelLocks;
  const auth = join(temporary, 'auth.json');
  writeFileSync(auth, JSON.stringify({synthetic: {type: 'api_key', key: 'FAKE'}}));
  const runtime = await ModelRuntime.create({modelsPath: null, authPath: auth, allowModelNetwork: false});
  const expected = lock.models.map(model => `synthetic/${model.id}`).sort();
  const identities = models => models.map(model => `${model.provider}/${model.id}`).sort();
  const original = runtime.getProvider('synthetic');
  const extra = {...lock.models[0], id: 'outside'};
  runtime.registerProvider('foreign', {...lock, models: [extra]});
  runtime.registerProvider('synthetic', {...lock, baseUrl: 'https://wrong.invalid', models: [extra]});
  runtime.registerNativeProvider({...original, baseUrl: 'https://wrong.invalid', getModels: () => [extra]});
  runtime.registerVirtualModel({provider: 'foreign', id: 'virtual', name: 'Virtual',
    route: async () => ({model: {provider: 'foreign', id: 'outside'}, thinkingLevel: 'off'})});
  await runtime.refresh({allowNetwork: false});
  assert.deepEqual(identities(runtime.getModels()), expected);
  assert.deepEqual(identities(runtime.getAllModels()), expected);
  assert.deepEqual(identities(await runtime.getAvailable()), expected);
  assert.deepEqual(identities(await runtime.getAllAvailable()), expected);
  assert.equal(runtime.getModel('foreign', 'outside'), undefined);
  assert.equal(runtime.getPhysicalModel('foreign', 'virtual'), undefined);

  const urls = [];
  const fetch = async input => {
    urls.push(String(input));
    return new Response('data: {"id":"probe","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}\n\n'
      + 'data: {"id":"probe","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
      + 'data: [DONE]\n\n', {headers: {'content-type': 'text/event-stream'}});
  };
  const model = runtime.getModels()[0];
  const context = {messages: [{role: 'user', content: 'probe', timestamp: 0}]};
  const rejected = await runtime.streamSimple({...model, provider: 'foreign'}, context, {fetch}).result();
  assert.equal(rejected.stopReason, 'error');
  assert.match(rejected.errorMessage, /managed Synthetic lock/);
  assert.deepEqual(urls, []);
  const accepted = await runtime.streamSimple({...model, baseUrl: 'https://wrong.invalid'}, context, {fetch}).result();
  assert.equal(accepted.stopReason, 'stop', accepted.errorMessage);
  assert.deepEqual(urls, [lock.baseUrl + '/chat/completions']);
} finally {
  if (previousAgent === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgent;
  rmSync(temporary, {recursive: true, force: true});
}
