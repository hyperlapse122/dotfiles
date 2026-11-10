---
title: A tmpfs GNUPGHOME cannot reach the card, and import will not replace card stubs
date: "2026-09-21"
category: integration-issues
module: OpenPGP card provisioning
problem_type: integration_issue
component: authentication
severity: high
symptoms:
  - "`gpg --card-status` says `selecting card failed: No such device` while `ykman info` sees the same card"
  - "`gpg --import` of the key backup reports `secret keys unchanged` and the subkeys stay card stubs"
  - "`keytocard` on a second card has nothing to move, because every subkey already points at the first card"
root_cause: incomplete_setup
resolution_type: workflow_improvement
related_components:
  - tooling
tags: ["gnupg", "yubikey", "keytocard", "scdaemon", "pcsclite", "card-stubs"]
---

# A tmpfs GNUPGHOME cannot reach the card, and import will not replace card stubs

## Problem

The replacement-card step in `docs/recovery.md` ("Restore the backup into a tmpfs `GNUPGHOME`") tells the operator to provision a replacement YubiKey from the offline backup by restoring it into a tmpfs `GNUPGHOME` and moving the subkeys onto the card. Carried out literally, that procedure fails twice, and neither failure is explained by anything in this repository.

The tmpfs `GNUPGHOME` is the point of the exercise: it keeps secret key material off the SSD. But it is also a *fresh* GnuPG home, and the two settings that make cards work here are written into the real `~/.gnupg` by Home Manager, not carried by GnuPG itself.

## Symptoms

Provisioning the second of three cards during the ed25519 rotation:

```console
$ ykman info
Device type: YubiKey 5C NFC
Serial number: 37522734
OpenPGP        Enabled

$ gpg --card-status
gpg: selecting card failed: No such device
gpg: OpenPGP card not available: No such device
```

Then, after `keytocard` and `save` on the first card, re-importing the backup to provision the next one:

```console
$ gpg --import key-b-backup.asc
gpg: key 4945855D4F283F05: "Joosung Park <iam@h82.dev>" not changed
gpg: key 4945855D4F283F05: secret key imported
gpg: Total number processed: 1
gpg:       secret keys read: 1
gpg:  secret keys unchanged: 1

$ gpg --list-secret-keys --with-colons | awk -F: '/^ssb:/{print $5, $15}'
F757604B321FD368 D2760001240100000006375227340000
BD494A273E310036 D2760001240100000006375227340000
1E305FCE7BE9F27D D2760001240100000006375227340000
```

`secret keys imported: 1` reads like success. It is not: field 15 still carries the first card's serial, so all three subkeys are stubs and `keytocard` has no local secret to move.

## What Didn't Work

Reading `ykman info` as proof the card was reachable. `ykman` talks to the YubiKey through its own PC/SC path and succeeded throughout, which made the failure look like a GnuPG bug rather than a missing configuration file. `systemctl is-active pcscd` was also misleading: it reported `inactive` while `pcscd.socket` was `active`, which is correct socket activation and not the fault.

Trusting `gpg --import`'s summary line. `secret keys imported: 1` and `secret keys unchanged: 1` appear together, and the first is the one that catches the eye. Only the `--with-colons` card-serial field distinguishes a restored secret key from a stub.

## Solution

**Give the ceremony home its own `scdaemon.conf`**, with the same two settings the `scdaemon.conf` block in `home/h82/security/gpg.nix` writes into the real `~/.gnupg`:

```sh
cat >"$GNUPGHOME/scdaemon.conf" <<'EOF'
disable-ccid
pcsc-shared
EOF
gpgconf --kill scdaemon
```

`gpg --card-status` then finds the card immediately; no reboot or pcscd restart is needed.

**Delete the secret key before re-importing it** for the next card:

```sh
gpg --delete-secret-keys <FPR>          # removes the stubs, keeps the public key
gpg --import key-b-backup.asc
gpg --list-secret-keys --with-colons | awk -F: '/^ssb:/{print $5, $15}'
```

The check is the verification, not the import message: field 15 must read `+` (a local secret) rather than a card serial before `keytocard` is attempted.

## Why This Works

`services.pcscd.enable = true` at `modules/nixos/system/base.nix` runs pcscd (non-NixOS hosts run pcscd through `modules/system-manager/default.nix`), and pcscd holds the reader. Without `disable-ccid`, scdaemon prefers its own built-in CCID driver and contends with pcscd for the same device; `pcsc-shared` then lets it share the reader rather than demanding exclusive access. Home Manager writes both into `~/.gnupg/scdaemon.conf`, so every ordinary session inherits them and the constraint is invisible until a `GNUPGHOME` is created that Home Manager never touched.

The import behaviour is deliberate on GnuPG's part: a card stub records that the private key lives on specific hardware, and silently overwriting it with an on-disk copy would be a downgrade the user did not ask for. So import merges the public material, reports the secret key as `unchanged`, and leaves the stub. `keytocard` is what created the stub in the first place, which is why the trap only appears from the second card onward.

## Prevention

- Treat a throwaway `GNUPGHOME` as unconfigured, not as a copy of `~/.gnupg`. Anything the declarative configuration writes into the real home — `scdaemon.conf` here, and `gpg-agent.conf` for pinentry selection — has to be written again, or the ceremony inherits none of it.
- Verify card-stub state with `--with-colons` field 15 rather than the import summary. A provisioning script can assert it:

  ```sh
  oncard=$(gpg --list-secret-keys --with-colons | awk -F: '/^ssb:/{print $15}' | grep -cv '^+$')
  [ "$oncard" -eq 0 ] || { echo "subkeys are card stubs, not local secrets" >&2; exit 1; }
  ```

  The paper-restore script used during the rotation carries exactly this assertion, so a restore that comes back as stubs fails before any card is touched.
- Order the ceremony so the card is proven reachable *before* anything irreversible. `keytocard` destroys the local copy and `ykman openpgp reset` wipes a card; discovering a configuration gap after either is expensive.

## Out of scope

That a given card actually signs and decrypts after provisioning is a hardware check rather than a repository check (see `CONCEPTS.md` and `AGENTS.md`). Neither failure above is reachable by a repository check, because both require a real reader and a real card.
