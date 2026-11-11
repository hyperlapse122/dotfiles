import { readFileSync, writeFileSync, mkdtempSync, cpSync, rmSync, readdirSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
const temporary = mkdtempSync(join(tmpdir(), 'pi-policy-'));
try {
  cpSync(process.argv[2], temporary, { recursive: true, dereference: true });
  // Only the native provider inventory is stubbed; execute the actual policy.
  const policy = readFileSync(join(temporary, 'dotfiles-policy.ts'), 'utf8')
    .replace('import { getBuiltinProviders } from "@earendil-works/pi-ai/providers/all";', 'const getBuiltinProviders = () => ["foreign", "synthetic"];');
  writeFileSync(join(temporary, 'policy.mjs'), policy);
  const { default: install } = await import(pathToFileURL(join(temporary, 'policy.mjs')));
  const hooks = {}, providers = {};
  install({ registerProvider: (id, spec) => providers[id] = spec, on: (event, fn) => hooks[event] = fn });
  assert.deepEqual(providers.foreign.models, []);
  const ids = new Set(providers.synthetic.models.map(model => model.id));
  for (const model of [{provider: 'foreign', id: 'outside'}, {provider:'synthetic', id:'outside'}, {provider:'synthetic', id:[...ids][0]}]) {
    let stopped = false;
    process.exitCode = 0;
    await hooks.resources_discover({}, { model, shutdown: () => stopped = true,
      modelRegistry: { refresh: async () => {}, getAll: () => providers.synthetic.models.map(m => ({...m, provider:'synthetic'})) } });
    assert.equal(stopped, !ids.has(model.id));
    process.exitCode = 0;
  }
  let stopped = false;
  hooks.session_start({}, {shutdown: () => stopped = true, sessionManager: {getBranch: () => [{type:'model_change', provider:'foreign', modelId:'outside'}, {type:'message'}]}});
  assert(stopped);
  process.exitCode = 0;
} finally {
  // cpSync keeps the store's read-only modes, so rmSync cannot unlink entries
  // inside copied directories until they are writable again.
  for (const entry of readdirSync(temporary, { recursive: true, withFileTypes: true }))
    if (entry.isDirectory()) chmodSync(join(entry.parentPath, entry.name), 0o755);
  chmodSync(temporary, 0o755);
  rmSync(temporary, { recursive: true, force: true });
}
