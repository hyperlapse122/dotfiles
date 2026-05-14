#!/usr/bin/env node
// scripts/bootstrap/render-opencode-prompt-append.mjs
//
// Renders markdown prompt append files into oh-my-openagent.jsonc without
// requiring JSONC dependencies. The editor preserves surrounding comments and
// formatting by replacing only the target JSON string values.

import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../..');
const configPath = path.join(repoRoot, 'home/.config/opencode/oh-my-openagent.jsonc');

const promptAppends = [
  {
    agent: 'prometheus',
    promptPath: path.join(repoRoot, 'home/.config/opencode/prompts/prometheus_prompt_append.md'),
  },
  {
    agent: 'atlas',
    promptPath: path.join(repoRoot, 'home/.config/opencode/prompts/atlas_prompt_append.md'),
  },
];

const args = new Set(process.argv.slice(2));

if (args.has('--help') || args.has('-h')) {
  console.log(`Usage: render-opencode-prompt-append.mjs [--check]\n\nRenders prompt markdown files into prompt_append properties in:\n  ${path.relative(repoRoot, configPath)}\n\nOptions:\n  --check   Verify the config is already rendered; do not write changes.\n  -h, --help\n           Show this help.`);
  process.exit(0);
}

const unknownArgs = [...args].filter((arg) => arg !== '--check');
if (unknownArgs.length > 0) {
  throw new Error(`unknown argument(s): ${unknownArgs.join(', ')}`);
}

const checkOnly = args.has('--check');

let config = readFileSync(configPath, 'utf8');
const originalConfig = config;

for (const { agent, promptPath } of promptAppends) {
  const prompt = readFileSync(promptPath, 'utf8');
  config = replacePromptAppend(config, agent, prompt);
}

if (checkOnly) {
  if (config !== originalConfig) {
    console.error('render-opencode-prompt-append.mjs: config is out of date. Run scripts/bootstrap/render-opencode-prompt-append.sh or .ps1.');
    process.exit(1);
  }
  console.log('render-opencode-prompt-append.mjs: config is up to date.');
} else if (config !== originalConfig) {
  writeFileSync(configPath, config);
  console.log(`render-opencode-prompt-append.mjs: updated ${path.relative(repoRoot, configPath)}.`);
} else {
  console.log('render-opencode-prompt-append.mjs: no changes needed.');
}

/**
 * @param {string} text
 * @param {string} agent
 * @param {string} prompt
 */
function replacePromptAppend(text, agent, prompt) {
  const agentNameRange = findStringProperty(text, agent, 0, text.length);
  if (!agentNameRange) {
    throw new Error(`agent not found: ${agent}`);
  }

  const objectStart = text.indexOf('{', agentNameRange.end);
  if (objectStart === -1) {
    throw new Error(`object start not found for agent: ${agent}`);
  }

  const objectEnd = findMatchingBrace(text, objectStart);
  const promptAppendRange = findStringProperty(text, 'prompt_append', objectStart, objectEnd);
  if (!promptAppendRange) {
    throw new Error(`prompt_append not found for agent: ${agent}`);
  }

  const colon = findNextSyntaxChar(text, ':', promptAppendRange.end, objectEnd);
  const valueStart = findNextNonWhitespace(text, colon + 1, objectEnd);
  const valueEnd = findStringEnd(text, valueStart);

  return `${text.slice(0, valueStart)}${JSON.stringify(prompt.replaceAll('\r\n', '\n'))}${text.slice(valueEnd)}`;
}

/**
 * @param {string} text
 * @param {string} propertyName
 * @param {number} start
 * @param {number} end
 */
function findStringProperty(text, propertyName, start, end) {
  let index = start;
  while (index < end) {
    const stringRange = findNextString(text, index, end);
    if (!stringRange) {
      return null;
    }

    const raw = text.slice(stringRange.start, stringRange.end);
    if (JSON.parse(raw) === propertyName) {
      const colon = findNextSyntaxChar(text, ':', stringRange.end, end);
      if (colon !== -1) {
        return stringRange;
      }
    }
    index = stringRange.end;
  }
  return null;
}

/**
 * @param {string} text
 * @param {any} start
 * @param {number} end
 */
function findNextString(text, start, end) {
  let index = start;
  while (index < end) {
    if (text.startsWith('//', index)) {
      index = skipLineComment(text, index);
      continue;
    }
    if (text.startsWith('/*', index)) {
      index = skipBlockComment(text, index);
      continue;
    }
    if (text[index] === '"') {
      return { start: index, end: findStringEnd(text, index) };
    }
    index += 1;
  }
  return null;
}

/**
 * @param {string} text
 * @param {any} objectStart
 */
function findMatchingBrace(text, objectStart) {
  let depth = 0;
  let index = objectStart;
  while (index < text.length) {
    if (text.startsWith('//', index)) {
      index = skipLineComment(text, index);
      continue;
    }
    if (text.startsWith('/*', index)) {
      index = skipBlockComment(text, index);
      continue;
    }
    if (text[index] === '"') {
      index = findStringEnd(text, index);
      continue;
    }
    if (text[index] === '{') {
      depth += 1;
    } else if (text[index] === '}') {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
    index += 1;
  }
  throw new Error('matching closing brace not found');
}

/**
 * @param {string | any[]} text
 * @param {number} start
 */
function findStringEnd(text, start) {
  if (text[start] !== '"') {
    throw new Error(`expected string at offset ${start}`);
  }
  let escaped = false;
  for (let index = start + 1; index < text.length; index += 1) {
    const char = text[index];
    if (escaped) {
      escaped = false;
    } else if (char === '\\') {
      escaped = true;
    } else if (char === '"') {
      return index + 1;
    }
  }
  throw new Error(`unterminated string at offset ${start}`);
}

/**
 * @param {string} text
 * @param {string} char
 * @param {any} start
 * @param {number} end
 */
function findNextSyntaxChar(text, char, start, end) {
  let index = start;
  while (index < end) {
    if (text.startsWith('//', index)) {
      index = skipLineComment(text, index);
      continue;
    }
    if (text.startsWith('/*', index)) {
      index = skipBlockComment(text, index);
      continue;
    }
    if (text[index] === '"') {
      index = findStringEnd(text, index);
      continue;
    }
    if (text[index] === char) {
      return index;
    }
    index += 1;
  }
  return -1;
}

/**
 * @param {string} text
 * @param {any} start
 * @param {number} end
 */
function findNextNonWhitespace(text, start, end) {
  for (let index = start; index < end; index += 1) {
    if (!/\s/.test(text[index])) {
      return index;
    }
  }
  throw new Error(`non-whitespace character not found after offset ${start}`);
}

/**
 * @param {string | string[]} text
 * @param {number} start
 */
function skipLineComment(text, start) {
  const nextNewline = text.indexOf('\n', start + 2);
  return nextNewline === -1 ? text.length : nextNewline + 1;
}

/**
 * @param {string | string[]} text
 * @param {number} start
 */
function skipBlockComment(text, start) {
  const commentEnd = text.indexOf('*/', start + 2);
  if (commentEnd === -1) {
    throw new Error(`unterminated block comment at offset ${start}`);
  }
  return commentEnd + 2;
}
