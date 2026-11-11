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
  const models = JSON.parse(readFileSync(join(temporary, 'model-lock.json'), 'utf8')).syntheticModelLocks.models;
  const ids = new Set(models.map(model => model.id));
  for (const model of [{provider: 'foreign', id: 'outside'}, {provider:'synthetic', id:'outside'}, {provider:'synthetic', id:[...ids][0]}]) {
    let stopped = false;
    process.exitCode = 0;
    await hooks.resources_discover({}, { model, shutdown: () => stopped = true,
      modelRegistry: { refresh: async () => {}, getAll: () => models.map(m => ({...m, provider:'synthetic'})) } });
    assert.equal(stopped, !ids.has(model.id));
    process.exitCode = 0;
  }
  let stopped = false;
  hooks.session_start({}, {shutdown: () => stopped = true, sessionManager: {getBranch: () => [{type:'model_change', provider:'foreign', modelId:'outside'}, {type:'message'}]}});
  assert(stopped);
  process.exitCode = 0;
} finally { rmSync(temporary, { recursive: true, force: true }); }
