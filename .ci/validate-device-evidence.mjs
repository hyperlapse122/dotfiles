#!/usr/bin/env node
// Device evidence validator and shared gate-evaluation library.
//
// This module is imported by .ci/evaluate-cutover-gates.mjs and is also a
// standalone CLI. It implements:
//   - a strict JSON Schema subset interpreter (unknown/missing fields fail)
//   - canonical JSON + sha256 (support-matrix snapshot digests)
//   - secret-shaped value rejection
//   - protected-policy trust binding for device evidence records
//   - offline Sigstore bundle subject cross-check (cryptographic verification
//     stays with `gh attestation verify` in the protected workflow)
//
// CLI:
//   node .ci/validate-device-evidence.mjs \
//     --gates <default-branch cutover-gates.json> \
//     --support-matrix <support-matrix.json> \
//     --candidate-commit <40-hex sha> \
//     (--evidence <file> [--evidence <file>...] | --evidence-dir <dir>)
//
// Exit 0: every evidence record is schema-valid AND trust-bound.
// Exit 1: any rejection; stdout JSON is {"valid":false,"errors":[...]}.
//
// TRUST CONTRACT: --gates MUST be the default-branch copy of
// .ci/cutover-gates.json. A candidate-checkout policy defeats the control.
// CI must also verify this file's sha256 against policy.trustedEvaluators
// before invoking it.

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

export function readJson(file) {
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (err) {
    throw new Error(`${file}: unreadable: ${err.message}`);
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`${file}: invalid JSON: ${err.message}`);
  }
}

export function canonicalJson(value) {
  if (Array.isArray(value)) {
    return '[' + value.map(canonicalJson).join(',') + ']';
  }
  if (value !== null && typeof value === 'object') {
    return (
      '{' +
      Object.keys(value)
        .sort()
        .map((key) => JSON.stringify(key) + ':' + canonicalJson(value[key]))
        .join(',') +
      '}'
    );
  }
  return JSON.stringify(value);
}

export function sha256Hex(data) {
  return createHash('sha256').update(data).digest('hex');
}

export function snapshotDigest(matrix) {
  return sha256Hex(canonicalJson(matrix));
}

function deepEqual(a, b) {
  return canonicalJson(a) === canonicalJson(b);
}

// Gate outcomes are mutable records. Everything else in the policy is an
// authorization input and must remain identical to the policy at the measured
// commit when evidence is carried forward by a later record-only commit.
const MUTABLE_GATE_OUTCOME_FIELDS = new Set([
  'status',
  'reason',
  'candidateCommit',
  'supportSnapshot',
  'evidence'
]);

export function policyAuthorizationView(policy) {
  const view = structuredClone(policy);
  for (const gate of Object.values(view.gates ?? {})) {
    for (const field of MUTABLE_GATE_OUTCOME_FIELDS) {
      delete gate[field];
    }
  }
  return view;
}

export function comparePolicyAuthorization(measuredPolicy, currentPolicy) {
  return deepEqual(policyAuthorizationView(measuredPolicy), policyAuthorizationView(currentPolicy))
    ? []
    : [
        'protected policy authorization changed after measurement; only gate outcome fields ' +
          '(status, reason, candidateCommit, supportSnapshot, evidence) may change'
      ];
}

// ---------------------------------------------------------------------------
// Strict JSON Schema subset interpreter
// Supported: type, const, enum, pattern, minLength, maxLength, required,
// properties, patternProperties, propertyNames, additionalProperties (false
// or schema), items, minItems, uniqueItems, minProperties, oneOf, $ref (local
// #/... pointers), description/title/$id/$schema (ignored metadata).
// ---------------------------------------------------------------------------

function resolveRef(ref, root) {
  if (typeof ref !== 'string' || !ref.startsWith('#/')) {
    throw new Error(`unsupported $ref ${JSON.stringify(ref)}`);
  }
  let node = root;
  for (const part of ref.slice(2).split('/')) {
    node = node?.[part];
  }
  if (node === undefined) {
    throw new Error(`unresolvable $ref ${ref}`);
  }
  return node;
}

export function validateSchema(value, schema, valuePath = '$', root = schema) {
  const errors = [];

  const walk = (v, s, p) => {
    if (s === null || typeof s !== 'object') {
      throw new Error(`malformed schema at ${p}`);
    }
    if (s.$ref !== undefined) {
      s = resolveRef(s.$ref, root);
    }

    if (s.const !== undefined && !deepEqual(v, s.const)) {
      errors.push(`${p}: must be ${JSON.stringify(s.const)}`);
      return;
    }
    if (s.enum !== undefined && !s.enum.some((entry) => deepEqual(entry, v))) {
      errors.push(`${p}: must be one of ${s.enum.map((entry) => JSON.stringify(entry)).join(', ')}`);
      return;
    }
    if (s.oneOf !== undefined) {
      const matches = s.oneOf.filter((sub) => validateSchema(v, sub, p, root).length === 0);
      if (matches.length !== 1) {
        errors.push(`${p}: must match exactly one allowed form (matched ${matches.length})`);
      }
    }

    if (s.type !== undefined) {
      const ok =
        s.type === 'object'
          ? v !== null && typeof v === 'object' && !Array.isArray(v)
          : s.type === 'array'
            ? Array.isArray(v)
            : s.type === 'string'
              ? typeof v === 'string'
              : s.type === 'integer'
                ? Number.isInteger(v)
                : s.type === 'boolean'
                  ? typeof v === 'boolean'
                  : false;
      if (!ok) {
        errors.push(`${p}: expected ${s.type}`);
        return;
      }
    }

    if (typeof v === 'string') {
      if (s.pattern !== undefined && !new RegExp(s.pattern).test(v)) {
        errors.push(`${p}: value fails pattern ${s.pattern}`);
      }
      if (s.minLength !== undefined && v.length < s.minLength) {
        errors.push(`${p}: shorter than minLength ${s.minLength}`);
      }
      if (s.maxLength !== undefined && v.length > s.maxLength) {
        errors.push(`${p}: longer than maxLength ${s.maxLength}`);
      }
    }

    if (Array.isArray(v)) {
      if (s.minItems !== undefined && v.length < s.minItems) {
        errors.push(`${p}: fewer than minItems ${s.minItems}`);
      }
      if (s.uniqueItems === true) {
        const canonicalItems = v.map(canonicalJson);
        for (let i = 0; i < canonicalItems.length; i += 1) {
          for (let j = i + 1; j < canonicalItems.length; j += 1) {
            if (canonicalItems[i] === canonicalItems[j]) {
              errors.push(`${p}: duplicate items at [${i}] and [${j}]`);
            }
          }
        }
      }
      if (s.items !== undefined) {
        v.forEach((item, index) => walk(item, s.items, `${p}[${index}]`));
      }
    }

    if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
      const keys = Object.keys(v);
      if (s.minProperties !== undefined && keys.length < s.minProperties) {
        errors.push(`${p}: fewer than minProperties ${s.minProperties}`);
      }
      if (s.propertyNames?.pattern !== undefined) {
        const nameRe = new RegExp(s.propertyNames.pattern);
        for (const key of keys) {
          if (!nameRe.test(key)) {
            errors.push(`${p}: field name '${key}' fails pattern ${s.propertyNames.pattern}`);
          }
        }
      }
      for (const required of s.required ?? []) {
        if (!(required in v)) {
          errors.push(`${p}: missing required field '${required}'`);
        }
      }
      const patterns = Object.entries(s.patternProperties ?? {});
      for (const key of keys) {
        let known = false;
        if (s.properties !== undefined && key in s.properties) {
          walk(v[key], s.properties[key], `${p}.${key}`);
          known = true;
        }
        for (const [pattern, sub] of patterns) {
          if (new RegExp(pattern).test(key)) {
            walk(v[key], sub, `${p}.${key}`);
            known = true;
          }
        }
        if (!known) {
          if (s.additionalProperties === false) {
            errors.push(`${p}: unknown field '${key}'`);
          } else if (s.additionalProperties !== null && typeof s.additionalProperties === 'object') {
            walk(v[key], s.additionalProperties, `${p}.${key}`);
          }
        }
      }
    }
  };

  walk(value, schema, valuePath);
  return errors;
}

// ---------------------------------------------------------------------------
// Secret-shaped value rejection (evidence is published; never carries secrets)
// ---------------------------------------------------------------------------

export const SECRET_PATTERNS = [
  [/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/, 'PEM private key'],
  [/-----BEGIN OPENSSH PRIVATE KEY-----/, 'OpenSSH private key'],
  [/op:\/\/[A-Za-z0-9/_.-]+/, '1Password reference'],
  [/ghp_[A-Za-z0-9]{20,}/, 'GitHub personal access token'],
  [/github_pat_[A-Za-z0-9_]{20,}/, 'GitHub fine-grained token'],
  [/gho_[A-Za-z0-9]{20,}/, 'GitHub OAuth token'],
  [/glpat-[A-Za-z0-9_-]{20,}/, 'GitLab personal access token'],
  [/xox[baprs]-[A-Za-z0-9-]{10,}/, 'Slack token'],
  [/AKIA[0-9A-Z]{16}/, 'AWS access key id'],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{10,}/, 'bearer token'],
  [/eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, 'JWT'],
  [/\b(?:password|passwd|api[_-]?key|secret|access[_-]?token)\s*[:=]\s*\S{8,}/i, 'credential assignment']
];

export function scanSecrets(value, valuePath = '$') {
  const errors = [];
  const walk = (v, p) => {
    if (typeof v === 'string') {
      for (const [re, label] of SECRET_PATTERNS) {
        if (re.test(v)) {
          errors.push(`${p}: secret-shaped value (${label})`);
        }
      }
    } else if (Array.isArray(v)) {
      v.forEach((item, index) => walk(item, `${p}[${index}]`));
    } else if (v !== null && typeof v === 'object') {
      for (const [key, item] of Object.entries(v)) {
        walk(item, `${p}.${key}`);
      }
    }
  };
  walk(value, valuePath);
  return errors;
}

// ---------------------------------------------------------------------------
// Trust binding: evidence record against the protected (default-branch) policy
// ---------------------------------------------------------------------------

export function normalizeArch(raw) {
  const lowered = String(raw).toLowerCase();
  if (lowered === 'x86_64' || lowered === 'amd64') return 'x64';
  if (lowered === 'aarch64' || lowered === 'arm64') return 'arm64';
  return null;
}

function sortedEqual(a, b) {
  if (a.length !== b.length) return false;
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.every((entry, index) => entry === sb[index]);
}

export function checkEvidenceTrust(evidence, policy, { candidateCommit, snapshotDigestHex }) {
  const errors = [];
  const att = evidence.attestation;
  const prefix = `evidence(device '${evidence.device?.id ?? '?'}')`;

  // Attestation binding: kind, issuer, repository, default-branch workflow
  // identity, protected environment. The schema already pins kind/issuer
  // constants; the policy comparison is what fails closed on identity drift.
  if (att.issuer !== policy.attestation.issuer) {
    errors.push(`${prefix}: attestation issuer '${att.issuer}' is not the trusted issuer`);
  }
  if (att.repository !== policy.repository) {
    errors.push(`${prefix}: attestation repository '${att.repository}' is not '${policy.repository}'`);
  }
  let workflowTrusted = false;
  for (const [workflowPath, pinned] of Object.entries(policy.attestation.signerWorkflows)) {
    const expectedRef = `${policy.repository}/${workflowPath}@refs/heads/${policy.defaultBranch}`;
    if (att.workflowRef === expectedRef) {
      workflowTrusted = true;
      if (att.workflowSha !== pinned.defaultBranchSha) {
        errors.push(
          `${prefix}: attestation workflowSha '${att.workflowSha}' does not match the pinned default-branch signer workflow SHA`
        );
      }
    }
  }
  if (!workflowTrusted) {
    errors.push(
      `${prefix}: attestation workflowRef '${att.workflowRef}' is not a trusted default-branch signer workflow`
    );
  }
  if (att.environment !== policy.protectedEnvironment) {
    errors.push(
      `${prefix}: attestation environment '${att.environment}' is not the protected environment '${policy.protectedEnvironment}'`
    );
  }

  // Trusted collector identity (digest pinned on the default branch).
  const trustedCollector = policy.trustedCollectors[evidence.collector.path];
  if (trustedCollector === undefined) {
    errors.push(`${prefix}: collector '${evidence.collector.path}' is not in the trusted collector policy`);
  } else if (trustedCollector !== evidence.collector.sha256) {
    errors.push(`${prefix}: collector sha256 does not match the trusted default-branch digest`);
  }

  // Protected positive device allowlist.
  const allowed = policy.devices.find((device) => device.id === evidence.device.id);
  if (!allowed) {
    errors.push(`${prefix}: device '${evidence.device.id}' is not in the protected device allowlist`);
  } else {
    if (allowed.status === 'revoked') {
      errors.push(`${prefix}: device '${evidence.device.id}' is revoked`);
    }
    if (allowed.os !== evidence.device.os || allowed.arch !== evidence.device.arch) {
      errors.push(`${prefix}: device os/arch does not match the allowlist entry`);
    }
    if (allowed.runnerClass !== evidence.device.runnerClass) {
      errors.push(`${prefix}: device runner class does not match the allowlist entry`);
    }
    if (!sortedEqual(allowed.runnerLabels, evidence.device.runnerLabels)) {
      errors.push(`${prefix}: device runner labels do not exactly match the allowlist entry`);
    }
  }

  // Every emitted check must be a claim that the protected policy actually
  // requests for this device. A check name is not proof by itself, and
  // duplicate or candidate-invented claims fail closed before gate scoring.
  const applicableClaims = new Set();
  for (const gate of Object.values(policy.gates)) {
    for (const leg of gate.mandatoryLegs) {
      const subject = leg.subject;
      if (
        (subject.os === undefined || subject.os === evidence.device.os) &&
        (subject.arch === undefined || subject.arch === evidence.device.arch) &&
        (subject.runnerClass === undefined || subject.runnerClass === evidence.device.runnerClass)
      ) {
        for (const claim of leg.claims) applicableClaims.add(claim);
      }
    }
  }
  const seenChecks = new Set();
  for (const check of evidence.measurements.checks) {
    if (seenChecks.has(check.name)) {
      errors.push(`${prefix}: duplicate measurement check '${check.name}'`);
    }
    seenChecks.add(check.name);
    if (!applicableClaims.has(check.name)) {
      errors.push(`${prefix}: measurement check '${check.name}' is not requested by protected policy for this device`);
    }
  }

  // Measured-subject binding: candidate commit and support snapshot.
  if (evidence.candidate.commit !== candidateCommit) {
    errors.push(`${prefix}: candidate commit '${evidence.candidate.commit}' is not the commit under evaluation`);
  }
  if (evidence.supportSnapshot.sha256 !== snapshotDigestHex) {
    errors.push(`${prefix}: support snapshot digest does not match the support matrix under evaluation`);
  }

  // Runtime architecture assertion.
  const observed = normalizeArch(evidence.measurements.runtimeArch);
  if (observed === null || observed !== evidence.device.arch) {
    errors.push(
      `${prefix}: runtime architecture '${evidence.measurements.runtimeArch}' does not match device arch '${evidence.device.arch}'`
    );
  }

  return errors;
}

// ---------------------------------------------------------------------------
// Offline Sigstore bundle subject cross-check. Cryptographic verification
// against the GitHub/Sigstore trust root stays with `gh attestation verify`
// in the protected workflow; here we bind the bundle's in-toto subject to the
// evidence file bytes so a swapped or self-made bundle fails closed.
// ---------------------------------------------------------------------------

export function checkBundle(evidenceFile, evidence) {
  const errors = [];
  const bundleFile = path.resolve(path.dirname(evidenceFile), evidence.attestation.bundlePath);
  if (!existsSync(bundleFile)) {
    return errors; // crypto verification happens in the protected workflow
  }
  let bundle;
  try {
    bundle = JSON.parse(readFileSync(bundleFile, 'utf8'));
  } catch (err) {
    errors.push(`${bundleFile}: invalid Sigstore bundle JSON: ${err.message}`);
    return errors;
  }
  const payloadB64 = bundle?.dsseEnvelope?.payload;
  if (typeof payloadB64 !== 'string' || payloadB64.length === 0) {
    errors.push(`${bundleFile}: bundle carries no dsseEnvelope.payload (not an artifact attestation bundle)`);
    return errors;
  }
  let statement;
  try {
    statement = JSON.parse(Buffer.from(payloadB64, 'base64').toString('utf8'));
  } catch {
    errors.push(`${bundleFile}: dsseEnvelope.payload is not a base64 in-toto statement`);
    return errors;
  }
  if (typeof statement?._type !== 'string' || !statement._type.startsWith('https://in-toto.io/Statement')) {
    errors.push(`${bundleFile}: payload is not an in-toto Statement`);
    return errors;
  }
  const subjects = Array.isArray(statement.subject) ? statement.subject : [];
  if (subjects.length === 0) {
    errors.push(`${bundleFile}: in-toto statement has no subjects`);
    return errors;
  }
  const localDigest = sha256Hex(readFileSync(evidenceFile));
  if (!subjects.some((subject) => subject?.digest?.sha256 === localDigest)) {
    errors.push(`${bundleFile}: no in-toto subject digest matches sha256 of the evidence file`);
  }
  return errors;
}

// ---------------------------------------------------------------------------
// Whole-record validation used by both the CLI and the gate evaluator
// ---------------------------------------------------------------------------

export function loadSchemas() {
  const dir = path.dirname(new URL(import.meta.url).pathname);
  return {
    matrix: readJson(path.join(dir, 'support-matrix.schema.json')),
    policy: readJson(path.join(dir, 'cutover-gates.schema.json')),
    evidence: readJson(path.join(dir, 'device-evidence.schema.json'))
  };
}

export function validateEvidenceFile(evidenceFile, evidenceSchema, policy, context) {
  const errors = [];
  let evidence;
  try {
    evidence = readJson(evidenceFile);
  } catch (err) {
    return { evidence: null, errors: [err.message] };
  }
  for (const message of validateSchema(evidence, evidenceSchema, evidenceFile)) {
    errors.push(message);
  }
  if (errors.length > 0) {
    return { evidence, errors }; // shape is untrusted; deeper checks need known fields
  }
  for (const message of scanSecrets(evidence, evidenceFile)) {
    errors.push(message);
  }
  for (const message of checkEvidenceTrust(evidence, policy, context)) {
    errors.push(`${evidenceFile}: ${message}`);
  }
  for (const message of checkBundle(evidenceFile, evidence)) {
    errors.push(message);
  }
  return { evidence, errors };
}

// ---------------------------------------------------------------------------
// CLI argument parsing (shared shape with the evaluator)
// ---------------------------------------------------------------------------

export function parseArgs(argv) {
  const args = { evidence: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`${flag} requires a value`);
      return argv[i];
    };
    switch (flag) {
      case '--gates':
        args.gates = next();
        break;
      case '--support-matrix':
        args.matrix = next();
        break;
      case '--measured-gates':
        args.measuredGates = next();
        break;
      case '--candidate-commit':
        args.candidateCommit = next();
        break;
      case '--evidence':
        args.evidence.push(next());
        break;
      case '--evidence-dir':
        args.evidenceDir = next();
        break;
      case '--require':
        args.require = next();
        break;
      default:
        throw new Error(`unknown argument '${flag}'`);
    }
  }
  return args;
}

export function evidenceFilesFromDir(dir) {
  if (!existsSync(dir)) {
    throw new Error(`evidence directory '${dir}' does not exist (fail closed)`);
  }
  return readdirSync(dir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => path.join(dir, name));
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
  if (!args.gates || !args.matrix || !args.candidateCommit) {
    console.error('required: --gates <policy> --support-matrix <matrix> --candidate-commit <sha>');
    process.exit(1);
  }
  if (!/^[0-9a-f]{40}$/.test(args.candidateCommit)) {
    console.error('--candidate-commit must be a 40-hex git SHA');
    process.exit(1);
  }

  const errors = [];
  let policy;
  let matrix;
  const schemas = loadSchemas();
  try {
    policy = readJson(args.gates);
    errors.push(...validateSchema(policy, schemas.policy, args.gates));
  } catch (err) {
    errors.push(err.message);
  }
  try {
    matrix = readJson(args.matrix);
    errors.push(...validateSchema(matrix, schemas.matrix, args.matrix));
  } catch (err) {
    errors.push(err.message);
  }
  if (errors.length > 0) {
    console.log(JSON.stringify({ valid: false, errors }, null, 2));
    process.exit(1);
  }

  let files = [...args.evidence];
  if (args.evidenceDir) {
    try {
      files.push(...evidenceFilesFromDir(args.evidenceDir));
    } catch (err) {
      console.log(JSON.stringify({ valid: false, errors: [err.message] }, null, 2));
      process.exit(1);
    }
  }
  if (files.length === 0) {
    console.log(JSON.stringify({ valid: false, errors: ['no evidence records supplied'] }, null, 2));
    process.exit(1);
  }

  const context = { candidateCommit: args.candidateCommit, snapshotDigestHex: snapshotDigest(matrix) };
  const accepted = [];
  for (const file of files) {
    const result = validateEvidenceFile(file, schemas.evidence, policy, context);
    if (result.errors.length > 0) {
      errors.push(...result.errors);
    } else {
      accepted.push(file);
    }
  }

  if (errors.length > 0) {
    console.log(JSON.stringify({ valid: false, errors }, null, 2));
    process.exit(1);
  }
  console.log(JSON.stringify({ valid: true, evidence: accepted.sort() }, null, 2));
  process.exit(0);
}

if (process.argv[1] && import.meta.url === `file://${path.resolve(process.argv[1])}`) {
  main();
}
