import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = dirname(dirname(realpathSync(join(process.argv[2], 'libexec/pi/pi'))));
const core = join(root, 'lib/pi/node_modules/@earendil-works/pi-coding-agent/dist/core');
const { resolveProjectTrusted } = await import(pathToFileURL(join(core, 'project-trust.js')));
const { ProjectTrustStore } = await import(pathToFileURL(join(core, 'trust-manager.js')));
const { SettingsManager } = await import(pathToFileURL(join(core, 'settings-manager.js')));
const agent = process.argv[3];
const project = join(agent, 'undecided');
mkdirSync(join(project, '.pi'), {recursive:true});
writeFileSync(join(project, '.pi/settings.json'), '{}');
const settings = SettingsManager.create(project, agent);
const trustStore = new ProjectTrustStore(agent);
const before = readFileSync(join(agent, 'trust.json'), 'utf8');
let prompts = 0;
const options = {cwd:project, trustStore, defaultProjectTrust:settings.getDefaultProjectTrust(),
  projectTrustContext:{hasUI:true, ui:{select:async (title, choices) => {
    prompts++;
    assert.match(title, /Trust project folder/);
    assert(choices.includes('Trust (this session only)'));
    return 'Trust (this session only)';
  }}}};
assert.equal(await resolveProjectTrusted(options), true);
assert.equal(prompts, 1, 'An undecided terminal project must ask');
assert.equal(readFileSync(join(agent, 'trust.json'), 'utf8'), before);
assert.equal(await resolveProjectTrusted({...options, trustOverride:true}), true);
assert.equal(prompts, 1, '--approve must skip the prompt');
assert.equal(readFileSync(join(agent, 'trust.json'), 'utf8'), before);
for (const decision of [false, true]) {
  trustStore.set(project, decision);
  assert.equal(await resolveProjectTrusted(options), decision);
  assert.equal(prompts, 1, 'Remembered decisions must not ask again');
}
