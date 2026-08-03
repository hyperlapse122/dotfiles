#!/usr/bin/env node
// Canonical cutover gate evaluator for G0 / G1a / G1b.
//
// CLI (consumed by .github/workflows/ci.yml evaluator-gates job):
//   node .ci/evaluate-cutover-gates.mjs \
//     --support-matrix <support matrix from measured commit> \
//     --gates <protected default-branch cutover-gates.json> \
//     --measured-gates <cutover-gates.json from measured commit> \
//     --evidence-dir .ci/device-evidence \
//     --candidate-commit <40-hex measured commit> \
//     [--require G0,G1b]   (default G0,G1b — the delivery gates; 'none' allowed)
//
// Stdout: canonical JSON
//   {"gates":[{"gate","status","reasons","evidence_commit","support_snapshot","evidence"}...]}
//
// Exit codes:
//   0  every required gate is open (all evidence valid)
//   1  invalid input or ANY invalid evidence record (fail closed)
//   2  evaluation succeeded but a required gate is closed
//
// TRUST CONTRACT:
//   - --gates MUST be the protected default-branch policy and
//     --measured-gates MUST come from the measured commit. Their authorization
//     content must be identical; only recorded gate outcomes may differ.
//   - --candidate-commit names the commit actually measured, not necessarily
//     the later record-only commit under CI. CI proves ancestry and the strict
//     post-measurement path allowlist before invoking this evaluator.
//   - CI MUST verify this file's sha256 against policy.trustedEvaluators.
//   - POLICY_FLOOR below hardcodes the product-contract minimum legs and
//     claims so a weakened policy still fails closed.

import {
  comparePolicyAuthorization,
  evidenceFilesFromDir,
  loadSchemas,
  normalizeArch,
  parseArgs,
  readJson,
  snapshotDigest,
  validateEvidenceFile,
  validateSchema
} from './validate-device-evidence.mjs';

const GATE_ORDER = ['G0', 'G1a', 'G1b'];
const DEFAULT_REQUIRE = ['G0', 'G1b'];

const INLINE_IMAGE_CLAIMS = [
  'inline-image-renders-in-tmux',
  'inline-image-survives-scroll',
  'inline-image-survives-redraw',
  'inline-image-survives-resize',
  'inline-image-survives-split'
];

// Product-contract floor (KTD12, R30, R34, R35, R18-R21). A policy missing
// any of these legs or claims is weakened and rejected before evaluation.
const POLICY_FLOOR = {
  G0: [
    {
      subject: { os: 'fedora', arch: 'arm64' },
      claims: ['chrome-native-arm64-available', 'cider-native-arm64-available', 'edge-native-arm64-available']
    }
  ],
  G1a: [
    {
      subject: { os: 'fedora' },
      claims: ['wezterm-kitty-unicode-placeholders-in-stable', 'wezterm-upstream-stable-rpm-for-current-fedora']
    },
    { subject: { os: 'windows' }, claims: ['wezterm-stable-winget-package'] },
    { subject: { os: 'macos' }, claims: ['wezterm-stable-homebrew-cask'] }
  ],
  G1b: [
    { subject: { os: 'fedora', runnerClass: 'self-hosted' }, claims: INLINE_IMAGE_CLAIMS },
    {
      subject: { os: 'windows', runnerClass: 'self-hosted' },
      claims: [...INLINE_IMAGE_CLAIMS, 'inline-image-over-ssh-to-fedora-vm']
    },
    { subject: { os: 'macos' }, claims: INLINE_IMAGE_CLAIMS }
  ]
};

function subjectMatches(subject, device) {
  if (subject.os !== undefined && subject.os !== device.os) return false;
  if (subject.arch !== undefined && subject.arch !== device.arch) return false;
  if (subject.runnerClass !== undefined && subject.runnerClass !== device.runnerClass) return false;
  return true;
}

function subjectCovers(floorSubject, legSubject) {
  // A policy leg covers a floor subject only when it constrains every floor
  // dimension to the same value (it may constrain more, never less).
  for (const key of ['os', 'arch', 'runnerClass']) {
    if (floorSubject[key] !== undefined && legSubject[key] !== floorSubject[key]) return false;
  }
  return true;
}

function describeSubject(subject) {
  return Object.entries(subject)
    .map(([key, value]) => `${key}=${value}`)
    .join(',');
}

function checkPolicyFloor(policy) {
  const errors = [];
  for (const gate of GATE_ORDER) {
    const legs = policy.gates[gate].mandatoryLegs;
    for (const floor of POLICY_FLOOR[gate]) {
      const covering = legs.filter((leg) => subjectCovers(floor.subject, leg.subject));
      if (covering.length === 0) {
        errors.push(
          `policy floor: ${gate} must include a mandatory leg for ${describeSubject(floor.subject)} (candidate-weakened policy fails closed)`
        );
        continue;
      }
      for (const claim of floor.claims) {
        if (!covering.some((leg) => leg.claims.includes(claim))) {
          errors.push(`policy floor: ${gate} leg for ${describeSubject(floor.subject)} must claim '${claim}'`);
        }
      }
    }
  }
  return errors;
}

function checkMatrix(matrix, policy) {
  const errors = [];
  const seen = new Set();
  for (const target of matrix.targets) {
    const key = `${target.os}/${target.arch}`;
    if (seen.has(key)) {
      errors.push(`support matrix: duplicate target '${key}'`);
    }
    seen.add(key);
    if (normalizeArch(target.runtimeArch) !== target.arch) {
      errors.push(`support matrix: target '${key}' runtimeArch does not match arch`);
    }
    if (target.kind === 'device') {
      const covered = policy.devices.some(
        (device) => device.status === 'active' && device.os === target.os && device.arch === target.arch
      );
      if (!covered) {
        errors.push(`support matrix: device target '${key}' has no active device in the protected allowlist`);
      }
    }
  }
  for (const required of ['fedora/x64', 'fedora/arm64', 'windows/x64', 'windows/arm64', 'macos/arm64']) {
    if (!seen.has(required)) {
      errors.push(`support matrix: required target '${required}' is missing`);
    }
  }
  for (const forbidden of ['macos/x64']) {
    if (seen.has(forbidden)) {
      errors.push(`support matrix: unsupported target '${forbidden}'`);
    }
  }
  return errors;
}

function evaluateLeg(leg, records) {
  const matching = records.filter((record) => subjectMatches(leg.subject, record.device));
  if (matching.length === 0) {
    return {
      ok: false,
      reasons: [`leg '${leg.id}': no trusted evidence for subject ${describeSubject(leg.subject)}`],
      record: null
    };
  }
  // Deterministic order: most claims satisfied, then newest, then device id.
  const scored = matching.map((record) => ({
    record,
    satisfied: leg.claims.filter((claim) =>
      record.measurements.checks.some((check) => check.name === claim && check.status === 'pass')
    ).length
  }));
  scored.sort(
    (a, b) =>
      b.satisfied - a.satisfied ||
      b.record.collectedAt.localeCompare(a.record.collectedAt) ||
      a.record.device.id.localeCompare(b.record.device.id)
  );
  for (const { record, satisfied } of scored) {
    if (satisfied === leg.claims.length) {
      return { ok: true, reasons: [], record };
    }
  }
  const best = scored[0].record;
  const reasons = [];
  for (const claim of leg.claims) {
    const check = best.measurements.checks.find((entry) => entry.name === claim);
    if (!check) {
      reasons.push(
        `leg '${leg.id}': claim '${claim}' absent from latest trusted evidence (device '${best.device.id}', collected ${best.collectedAt})`
      );
    } else if (check.status !== 'pass') {
      reasons.push(
        `leg '${leg.id}': claim '${claim}' status '${check.status}' in latest trusted evidence (device '${best.device.id}', collected ${best.collectedAt})`
      );
    }
  }
  return { ok: false, reasons, record: null };
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
  if (!args.gates || !args.measuredGates || !args.matrix || !args.candidateCommit) {
    console.error(
      'required: --support-matrix <measured matrix> --gates <protected policy> --measured-gates <measured policy> --candidate-commit <measured sha> [--evidence-dir <dir>] [--evidence <file>...] [--require G0,G1b|none]'
    );
    process.exit(1);
  }
  if (!/^[0-9a-f]{40}$/.test(args.candidateCommit)) {
    console.error('--candidate-commit must be a 40-hex git SHA');
    process.exit(1);
  }
  let required = DEFAULT_REQUIRE;
  if (args.require !== undefined) {
    required = args.require === 'none' ? [] : args.require.split(',');
    for (const gate of required) {
      if (!GATE_ORDER.includes(gate)) {
        console.error(`--require names unknown gate '${gate}'`);
        process.exit(1);
      }
    }
  }

  const schemas = loadSchemas();
  const inputErrors = [];
  let policy;
  let measuredPolicy;
  let matrix;
  try {
    policy = readJson(args.gates);
    inputErrors.push(...validateSchema(policy, schemas.policy, args.gates));
  } catch (err) {
    inputErrors.push(err.message);
  }
  try {
    measuredPolicy = readJson(args.measuredGates);
    inputErrors.push(...validateSchema(measuredPolicy, schemas.policy, args.measuredGates));
  } catch (err) {
    inputErrors.push(err.message);
  }
  try {
    matrix = readJson(args.matrix);
    inputErrors.push(...validateSchema(matrix, schemas.matrix, args.matrix));
  } catch (err) {
    inputErrors.push(err.message);
  }
  if (inputErrors.length === 0) {
    inputErrors.push(...comparePolicyAuthorization(measuredPolicy, policy));
    inputErrors.push(...checkPolicyFloor(policy));
    inputErrors.push(...checkMatrix(matrix, policy));
  }
  if (inputErrors.length > 0) {
    console.log(JSON.stringify({ errors: inputErrors }, null, 2));
    process.exit(1);
  }

  let files = [...args.evidence];
  if (args.evidenceDir) {
    try {
      files.push(...evidenceFilesFromDir(args.evidenceDir));
    } catch (err) {
      console.log(JSON.stringify({ errors: [err.message] }, null, 2));
      process.exit(1);
    }
  }

  const digest = snapshotDigest(matrix);
  const context = { candidateCommit: args.candidateCommit, snapshotDigestHex: digest };
  const valid = [];
  const evidenceErrors = [];
  for (const file of files) {
    const result = validateEvidenceFile(file, schemas.evidence, policy, context);
    if (result.errors.length > 0) {
      evidenceErrors.push(...result.errors);
    } else {
      valid.push(result.evidence);
    }
  }
  if (evidenceErrors.length > 0) {
    console.log(JSON.stringify({ errors: evidenceErrors }, null, 2));
    process.exit(1);
  }

  const gates = [];
  for (const gate of GATE_ORDER) {
    const reasons = [];
    const satisfiedEvidence = [];
    let open = true;
    if (gate === 'G1b' && gates.find((result) => result.gate === 'G1a')?.status !== 'open') {
      open = false;
      reasons.push('G1a prerequisite is closed');
    }
    for (const leg of policy.gates[gate].mandatoryLegs) {
      const outcome = evaluateLeg(leg, valid);
      if (outcome.ok) {
        satisfiedEvidence.push(`${outcome.record.device.id}@${outcome.record.collectedAt}`);
      } else {
        open = false;
        reasons.push(...outcome.reasons);
      }
    }
    gates.push({
      gate,
      status: open ? 'open' : 'closed',
      reasons,
      evidence_commit: args.candidateCommit,
      support_snapshot: digest,
      evidence: satisfiedEvidence.sort()
    });
  }

  console.log(JSON.stringify({ gates }, null, 2));

  const blocked = gates.filter((result) => required.includes(result.gate) && result.status !== 'open');
  if (blocked.length > 0) {
    process.exit(2);
  }
  process.exit(0);
}

main();
