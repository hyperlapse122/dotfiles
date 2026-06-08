#!/usr/bin/env node
// scripts/bootstrap/configure-codex-config.mjs
//
// Merges the repo-tracked, shared OpenAI Codex settings in
// `codex-config.managed.toml` INTO the machine-local Codex config
// (`$CODEX_HOME/config.toml`, default `~/.codex/config.toml`) without
// disturbing machine-local state — most importantly the per-project trust
// table `[projects."<path>"]` that Codex writes back into that same file.
//
// Codex has no `include`/import directive and writes trust decisions into the
// user config.toml itself, so the file cannot be a dotbot symlink. This script
// is the alternative: it applies ONLY the keys declared in the managed file and
// preserves every other byte of the live config.
//
// It deliberately avoids a full TOML parser (the live file is sensitive — it
// sits next to auth.json). Instead it performs targeted, TOML-safe edits:
//   * update a managed key in place when it already exists, or
//   * insert it (root keys before the first table header; sub-table keys after
//     the table header; a brand-new table appended at EOF).
// If updating a key would require touching a multi-line value it cannot safely
// reason about, it ABORTS without writing rather than risk corrupting the file.
//
// Usage: configure-codex-config.mjs [--check] [--print] [--no-backup]
//   --check       Exit 1 if the live config would change; write nothing.
//   --print       Print the would-be result to stdout; write nothing.
//   --no-backup   Do not write a <config>.bak before changing the live file.
//   -h, --help    Show this help.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../..');
const managedPath = path.join(repoRoot, 'codex', 'codex-config.managed.toml');

const codexHome =
  process.env.CODEX_HOME && process.env.CODEX_HOME.trim() !== ''
    ? process.env.CODEX_HOME
    : path.join(os.homedir(), '.codex');
const configPath = path.join(codexHome, 'config.toml');

const args = new Set(process.argv.slice(2));

if (args.has('--help') || args.has('-h')) {
  process.stdout.write(
    [
      'Usage: configure-codex-config.mjs [--check] [--print] [--no-backup]',
      '',
      `Applies the shared settings in ${path.relative(process.cwd(), managedPath)}`,
      `into the machine-local Codex config ${configPath}, preserving machine-local`,
      'state such as the [projects] trust table.',
      '',
      'Options:',
      '  --check       Exit 1 if the live config would change; write nothing.',
      '  --print       Print the would-be result to stdout; write nothing.',
      '  --no-backup   Do not write a <config>.bak before changing the live file.',
      '  -h, --help    Show this help.',
      '',
    ].join('\n'),
  );
  process.exit(0);
}

const knownFlags = new Set(['--check', '--print', '--no-backup']);
const unknown = [...args].filter((a) => !knownFlags.has(a));
if (unknown.length > 0) {
  fail(`unknown argument(s): ${unknown.join(', ')}`);
}

const checkOnly = args.has('--check');
const printOnly = args.has('--print');
const noBackup = args.has('--no-backup');

if (!existsSync(managedPath)) {
  fail(`managed settings file not found: ${managedPath}`);
}

const assignments = parseManagedToml(readFileSync(managedPath, 'utf8'));

const configExisted = existsSync(configPath);
const original = configExisted ? readFileSync(configPath, 'utf8') : '';

let result = original;
for (const { table, key, value } of assignments) {
  result = applyAssignment(result, table, key, value);
}

if (printOnly) {
  process.stdout.write(result);
  process.exit(0);
}

if (result === original) {
  if (assignments.length === 0) {
    log('no managed settings declared; nothing to do.');
  } else {
    log('config already up to date; no changes needed.');
  }
  process.exit(0);
}

if (checkOnly) {
  fail(
    `config is out of date. Run scripts/bootstrap/configure-codex-config.sh (or .ps1) to apply ${path.relative(
      process.cwd(),
      managedPath,
    )}.`,
  );
}

if (!existsSync(codexHome)) {
  mkdirSync(codexHome, { recursive: true });
}
if (configExisted && !noBackup) {
  writeFileSync(`${configPath}.bak`, original);
}
writeFileSync(configPath, result);
log(`${configExisted ? 'updated' : 'created'} ${configPath}.`);
process.exit(0);

// --------------------------------------------------------------------------
// Managed-file parsing (constrained "simple TOML").
// --------------------------------------------------------------------------

/**
 * Parse the managed settings file into ordered { table, key, value } records.
 * `table` is '' for the root table. `key` and `value` are the raw left/right
 * text of the first top-level `=` on the line.
 * @param {string} text
 * @returns {{ table: string, key: string, value: string }[]}
 */
function parseManagedToml(text) {
  /** @type {{ table: string, key: string, value: string }[]} */
  const out = [];
  let table = '';
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) {
      continue;
    }
    if (line.startsWith('[')) {
      const header = parseTableHeader(line);
      if (header === null) {
        fail(`managed file line ${i + 1}: unsupported table header: ${line}`);
      }
      if (header === 'projects' || header.startsWith('projects.')) {
        fail(
          `managed file line ${i + 1}: refusing to manage the machine-local [projects] table.`,
        );
      }
      table = header;
      continue;
    }
    const eq = line.indexOf('=');
    if (eq === -1) {
      fail(`managed file line ${i + 1}: expected 'key = value' or a [table] header: ${line}`);
    }
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    if (key === '') {
      fail(`managed file line ${i + 1}: empty key.`);
    }
    if (value === '') {
      fail(`managed file line ${i + 1}: empty value for key '${key}'.`);
    }
    if (!isSingleLineValue(value)) {
      fail(
        `managed file line ${i + 1}: value for '${key}' is not single-line/balanced; ` +
          'multi-line values are not supported in the managed file.',
      );
    }
    out.push({ table, key, value });
  }
  return out;
}

/**
 * Return the inside-bracket name of a standard `[table]` header, or null for
 * anything else (array-of-tables `[[x]]`, malformed, etc.).
 * @param {string} line
 * @returns {string | null}
 */
function parseTableHeader(line) {
  const m = /^\[([^[\]]+)\]$/.exec(line);
  return m ? m[1].trim() : null;
}

// --------------------------------------------------------------------------
// Targeted, TOML-safe editing of the live config.
// --------------------------------------------------------------------------

/**
 * Ensure `<key> = <value>` exists under `table` ('' = root) in `text`,
 * updating in place when present and inserting safely otherwise.
 * @param {string} text
 * @param {string} table
 * @param {string} key
 * @param {string} value
 * @returns {string}
 */
function applyAssignment(text, table, key, value) {
  const line = `${key} = ${value}`;
  const region = findTableRegion(text, table);

  if (region === null) {
    // Named table absent: append a fresh, well-formed table block at EOF.
    // (The root table always resolves to a region, so `table` is non-empty here.)
    let prefix = text;
    if (prefix !== '' && !prefix.endsWith('\n')) {
      prefix += '\n';
    }
    const sep = prefix === '' || prefix.endsWith('\n\n') ? '' : '\n';
    return `${prefix}${sep}[${table}]\n${line}\n`;
  }

  const existing = findKeyInRegion(text, region, key);
  if (existing) {
    if (!isSingleLineValue(text.slice(existing.valueStart, existing.lineEnd).trim())) {
      fail(
        `refusing to overwrite '${key}'${
          table ? ` in [${table}]` : ''
        }: existing value is multi-line/ambiguous in ${configPath}. ` +
          'Resolve it by hand, then re-run.',
      );
    }
    return `${text.slice(0, existing.lineStart)}${line}${text.slice(existing.lineEnd)}`;
  }

  // Key absent in an existing table region: insert at the end of the region so
  // declaration order is preserved. For the root table this lands just before
  // the first table header (or EOF); for a named table, just before the next
  // header (or EOF). Inserting at a region boundary keeps root keys ahead of
  // every table header, which is what TOML requires.
  const insertAt = region.end;
  const needsLeadingNl = insertAt > 0 && text[insertAt - 1] !== '\n';
  const insertion = `${needsLeadingNl ? '\n' : ''}${line}\n`;
  return `${text.slice(0, insertAt)}${insertion}${text.slice(insertAt)}`;
}

/**
 * Locate the byte region of `table` in `text`.
 * For the root table ('') returns { start: 0, headerEnd: 0, end } where end is
 * the start of the first table header (or text length). For a named table,
 * returns the body between its header and the next header (or EOF), with
 * `headerEnd` pointing just past the header line. Returns null if not found.
 * @param {string} text
 * @param {string} table
 * @returns {{ start: number, headerEnd: number, end: number } | null}
 */
function findTableRegion(text, table) {
  const headers = findHeaderLines(text);
  if (table === '') {
    const end = headers.length > 0 ? headers[0].start : text.length;
    return { start: 0, headerEnd: 0, end };
  }
  for (let i = 0; i < headers.length; i += 1) {
    if (headers[i].name === table) {
      const end = i + 1 < headers.length ? headers[i + 1].start : text.length;
      return { start: headers[i].end, headerEnd: headers[i].end, end };
    }
  }
  return null;
}

/**
 * Find every table/array-of-tables header line. `name` is the standard table
 * name, or null for array-of-tables headers (which only act as boundaries).
 * @param {string} text
 * @returns {{ start: number, end: number, name: string | null }[]}
 */
function findHeaderLines(text) {
  /** @type {{ start: number, end: number, name: string | null }[]} */
  const headers = [];
  let offset = 0;
  for (const raw of text.split('\n')) {
    const start = offset;
    const end = offset + raw.length + 1; // include the trailing '\n'
    offset = end;
    if (raw.trim().startsWith('[')) {
      headers.push({ start, end, name: parseTableHeader(raw.trim()) });
    }
  }
  return headers;
}

/**
 * Find an assignment for `key` within a region. Returns line/value offsets, or
 * null. Matches the key as the first token before `=` on a non-comment line.
 * @param {string} text
 * @param {{ start: number, end: number }} region
 * @param {string} key
 * @returns {{ lineStart: number, lineEnd: number, valueStart: number } | null}
 */
function findKeyInRegion(text, region, key) {
  let offset = region.start;
  const slice = text.slice(region.start, region.end);
  for (const raw of slice.split('\n')) {
    const lineStart = offset;
    const lineEnd = offset + raw.length; // excludes '\n'
    offset = lineEnd + 1;
    const trimmed = raw.trim();
    if (trimmed === '' || trimmed.startsWith('#')) {
      continue;
    }
    const eq = raw.indexOf('=');
    if (eq === -1) {
      continue;
    }
    if (raw.slice(0, eq).trim() === key) {
      return { lineStart, lineEnd, valueStart: lineStart + eq + 1 };
    }
  }
  return null;
}

/**
 * Heuristic: is `value` a complete single-line TOML value (balanced quotes,
 * brackets and braces, not opening a multi-line string)? Used both to validate
 * managed values and to refuse overwriting an ambiguous existing value.
 * @param {string} value
 * @returns {boolean}
 */
function isSingleLineValue(value) {
  if (value.includes('"""') || value.includes("'''")) {
    return false;
  }
  let inBasic = false; // "..."
  let inLiteral = false; // '...'
  let escaped = false;
  let square = 0;
  let curly = 0;
  for (const ch of value) {
    if (inBasic) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inBasic = false;
      continue;
    }
    if (inLiteral) {
      if (ch === "'") inLiteral = false;
      continue;
    }
    if (ch === '#') break; // start of a comment: rest is not value
    if (ch === '"') inBasic = true;
    else if (ch === "'") inLiteral = true;
    else if (ch === '[') square += 1;
    else if (ch === ']') square -= 1;
    else if (ch === '{') curly += 1;
    else if (ch === '}') curly -= 1;
    if (square < 0 || curly < 0) return false;
  }
  return !inBasic && !inLiteral && square === 0 && curly === 0;
}

/**
 * @param {string} message
 * @returns {never}
 */
function fail(message) {
  process.stderr.write(`configure-codex-config: ${message}\n`);
  process.exit(1);
}

/** @param {string} message */
function log(message) {
  process.stdout.write(`configure-codex-config: ${message}\n`);
}
