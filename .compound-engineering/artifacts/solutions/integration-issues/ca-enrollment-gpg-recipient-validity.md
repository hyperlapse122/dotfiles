---
title: CA enrollment fails without a TTY when the GPG recipient has unknown validity
date: 2026-11-07
category: integration-issues
module: CA-file fallback
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "scripts/ca-files.py import prints only 'CA enrollment encryption failed.'"
  - "gpg reports 'There is no assurance this key belongs to the named user' and 'cannot open /dev/tty'"
  - "scripts/ca-files.py import rejects a certificate file with 'CA input must contain only complete PEM CA certificates.'"
root_cause: config_error
resolution_type: environment_setup
tags: [ca, gpg, encryption, certificates, non-interactive, agents]
---

# CA enrollment fails without a TTY when the GPG recipient has unknown validity

## Problem

Enrolling a CA with `mise exec -- python scripts/ca-files.py import --id <id> --pem-file <path>` from an agent shell (no TTY) failed.
The importer withholds GPG diagnostics and only prints `CA enrollment encryption failed.`

## Symptoms

- Running the same encrypt command by hand shows `There is no assurance this key belongs to the named user` followed by `cannot open '/dev/tty': Device not configured`.
- `gpg --list-keys <recipient>` shows `[ unknown]` validity on the repository recipient's user IDs.
- Decryption of existing ciphertext in `home/.secrets/` works non-interactively, so the card and agent are fine.

## What Didn't Work

- Adding trust settings to `gpg.conf`: the importer runs gpg with `--no-options`, so the config file is ignored.
- Passing extra gpg arguments through chezmoi config: `require_encryption_policy` in `scripts/auth_common.py` rejects any `gpg.args` other than the exact pinned list.

## Solution

Two separate input problems had to be fixed.

1. **Text dump before the PEM.** The certificate file began with `openssl x509 -text` output. The importer accepts only PEM blocks. Normalize it outside the repository and compare fingerprints:

   ```sh
   openssl x509 -in input.pem -out "$SCRATCH/normalized.pem"
   openssl x509 -in input.pem -noout -fingerprint -sha256
   openssl x509 -in "$SCRATCH/normalized.pem" -noout -fingerprint -sha256
   ```

2. **Recipient validity prompt.** Choose one of these:
   - Run the import from an interactive terminal and answer the prompt, or
   - Have the key owner certify or ownertrust their own key (a personal keyring change; do not do it from automation), or
   - In automation, first confirm the recipient fingerprint equals `gpgRecipient` in `home/.chezmoidata/gpg.yaml`. Then call the importer's own `enroll()` in-process, adding `--trust-model always` only to the `--encrypt` call, and verify with `read_inventory()`. This keeps the importer's validation, decrypt-verify, and atomic publication.

## Why This Works

GPG asks for confirmation before encrypting to a key whose validity it cannot compute. With no TTY, that confirmation becomes a hard failure.
`--trust-model always` answers that question for one invocation only, so the fingerprint check is the trust decision.

## Prevention

- Before blaming the card or agent, run the importer's encrypt command by hand to see the GPG stderr that the script hides.
- A durable fix needs product code: either let `scripts/ca-files.py` (and the shared policy in `scripts/auth_common.py`) encrypt with an explicit trust model after checking the pinned fingerprint, or surface a specific error when encryption fails on recipient validity.

## Related

- [Opt-in CA-file fallback](../../../../docs/guides/system-ca.md#opt-in-ca-file-fallback)
- [GitHub CLI CA bundle overrides Windows platform trust](github-cli-windows-ca-override.md)
