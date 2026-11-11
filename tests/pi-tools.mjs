import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const temporary = mkdtempSync(join(tmpdir(), 'pi-tools-'));
const launcher = realpathSync(join(process.argv[2], 'libexec/pi/pi'));
const core = join(dirname(dirname(launcher)), 'lib/pi/node_modules/@earendil-works/pi-coding-agent/dist/core');
const { loadExtensions } = await import(pathToFileURL(join(core, 'extensions/loader.js')));
const originalFetch = globalThis.fetch;
try {
  const loaded = await loadExtensions([join(process.argv[3], 'dotfiles-web.ts')], temporary);
  assert.deepEqual(loaded.errors, []);
  const tools = loaded.extensions.flatMap(extension => [...extension.tools.values()].map(tool => tool.definition));
  assert.deepEqual(tools.map(tool => tool.name).sort(), ['web_fetch', 'web_search']);
  const call = (name, params, signal) => tools.find(tool => tool.name === name).execute('probe', params, signal, undefined, {});
  const keyFile = join(temporary, 'key');
  process.env.DOTFILES_PI_EXA_KEY_FILE = keyFile;
  const requests = [];
  let response = {results: [{title: 'Source title', url: 'https://example.org/actual', highlights: ['Useful extract']}]};
  globalThis.fetch = async (url, options) => {
    requests.push({url, ...options, body: JSON.parse(options.body)});
    return new Response(JSON.stringify(response));
  };
  const missing = await call('web_search', {query: 'probe'});
  assert.equal(missing.details.status, 'credentials_unavailable');
  assert.equal(requests.length, 0);
  for (const key of ['', 'first\nsecond', '   ']) {
    writeFileSync(keyFile, key);
    assert.equal((await call('web_search', {query: 'probe'})).details.status, 'credentials_unavailable');
  }
  // Reading a directory fails even when the test runs as a privileged user.
  process.env.DOTFILES_PI_EXA_KEY_FILE = temporary;
  assert.equal((await call('web_search', {query: 'probe'})).details.status, 'credentials_unavailable');
  process.env.DOTFILES_PI_EXA_KEY_FILE = keyFile;
  for (const key of ['FAKE-first', 'FAKE-rotated']) {
    writeFileSync(keyFile, key + '\n');
    const signal = new AbortController().signal;
    const result = await call('web_search', {query: 'probe'}, signal);
    assert.equal(result.details.status, 'ok');
    assert.match(result.content[0].text, /Source title[\s\S]*https:\/\/example.org\/actual[\s\S]*Useful extract/);
    assert.equal(requests.at(-1).url, 'https://api.exa.ai/search');
    assert.equal(requests.at(-1).headers['x-api-key'], key);
    assert.deepEqual(requests.at(-1).body, {query: 'probe', type: 'auto', numResults: 5, contents: {highlights: true}});
    assert.equal(requests.at(-1).signal, signal);
  }
  for (const params of [{query: ''}, {query:'x',count:0}, {query:'x',count:11}])
    assert.equal((await call('web_search', params)).details.status, 'invalid_input');
  for (const urls of [[], ['file:///etc/passwd'], ['http://localhost'], ['https://127.0.0.1/'], Array(6).fill('https://example.org')])
    assert.equal((await call('web_fetch', {urls})).details.status, 'invalid_input');
  response = {results: []};
  assert.equal((await call('web_search', {query:'x'})).details.status, 'empty');
  response = {results: [{url:'https://example.org/a', title:'A', text:'x'.repeat(15000)}], statuses: [
    {id:'https://example.org/a',status:'success'}, {id:'https://example.org/b',status:'error',error:{tag:'SECRET-raw-error'}}]};
  const partial = await call('web_fetch', {urls:['https://example.org/a','https://example.org/b']});
  assert.equal(partial.details.status, 'partial');
  assert.match(partial.content[0].text, /\[truncated\]/);
  assert.match(partial.content[0].text, /https:\/\/example.org\/b/);
  assert.doesNotMatch(JSON.stringify(partial), /SECRET/);
  assert.equal(requests.at(-1).url, 'https://api.exa.ai/contents');
  for (const status of [401,429,500]) {
    globalThis.fetch = async () => new Response('FAKE-rotated raw body', {status});
    const result = await call('web_search', {query:'x'});
    assert.equal(result.details.status, 'service_error');
    assert.doesNotMatch(JSON.stringify(result), /FAKE|raw body/);
  }
  globalThis.fetch = async () => new Response('{bad');
  assert.equal((await call('web_search', {query:'x'})).details.status, 'invalid_response');
  globalThis.fetch = async () => new Response('{"results":[{}]}');
  assert.equal((await call('web_search', {query:'x'})).details.status, 'invalid_response');
  globalThis.fetch = async () => { throw new Error('FAKE-rotated network details'); };
  const failure = await call('web_search', {query:'x'});
  assert.equal(failure.details.status, 'network_error');
  assert.doesNotMatch(JSON.stringify(failure), /FAKE|network details/);
  const abort = new AbortController();
  globalThis.fetch = (_url, {signal}) => new Promise((_resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), {once:true});
    abort.abort();
  });
  assert.equal((await call('web_search', {query:'x'}, abort.signal)).details.status, 'cancelled');
} finally {
  globalThis.fetch = originalFetch;
  delete process.env.DOTFILES_PI_EXA_KEY_FILE;
  rmSync(temporary, {recursive:true, force:true});
}
