# archinstall/

Arch Linux unattended provisioning. Each host has its own subdirectory under `archinstall/<hostname>/`.

## Layout

```
archinstall/
├── README.md                        # This file
├── post-install.sh                  # Hook: clone+bootstrap dotfiles after install
├── user_credentials.example.json    # Schema reference (only credentials file in git)
└── <hostname>/
    ├── user_configuration.json      # Disk, profile, packages, custom_commands
    ├── user_credentials.json        # GITIGNORED — passwords + LUKS keys
    └── initialize*.sh               # Optional host-specific legacy/manual scripts
```

## Bootstrap from the Arch live ISO

```sh
# 1. Get network on the live ISO (iwctl / dhcp / etc.)
# 2. Copy your host's configs onto the live system (USB, scp, curl, ...)
# 3. Run archinstall in silent mode:
archinstall \
  --config archinstall/<hostname>/user_configuration.json \
  --creds  archinstall/<hostname>/user_credentials.json \
  --silent
```

archinstall provisions the system, then runs `custom_commands` (defined in `user_configuration.json`) in `arch-chroot` of the new system before unmount. Those `custom_commands` end by invoking [`post-install.sh`](./post-install.sh), which clones this repo and runs `install.sh`. First boot lands on a fully linked system.

## Hosts

| Host | Source | Notes |
|---|---|---|
| `UX5606` | Migrated from `~/nix-config/dotfiles-legacy/archinstall/` | Tracks install choices and legacy initialization scripts. Credentials stay local in `archinstall/UX5606/user_credentials.json`. Generic bootstrap still goes through [`post-install.sh`](./post-install.sh); `initialize*.sh` are host-specific/manual legacy scripts. |

## post-install.sh

Designed for two callers:

1. **archinstall `custom_commands`** — runs as root inside `arch-chroot`. Pass the target username as `$1`.
2. **Manual re-run** on a freshly-installed Arch box (e.g. provisioned by another method). Same invocation.

Recommended `custom_commands` entry in `user_configuration.json`:

```json
"custom_commands": [
  "curl -fsSL https://raw.githubusercontent.com/hyperlapse122/dotfiles-next/main/archinstall/post-install.sh | bash -s -- <username>"
]
```

`<username>` MUST match `users[*].username` from `user_credentials.json`.

## Regenerating `user_configuration.json`

archinstall's JSON schema changes between releases. **Don't hand-edit fields you don't understand.** Regenerate:

```sh
archinstall --dry-run
# Walk through the TUI, then copy the produced config out:
cp /var/log/archinstall/user_configuration.json archinstall/<hostname>/user_configuration.json
```

The parser still accepts legacy keys (`audio_config`, `bootloader`, `!root-password`), but new configs SHOULD use the current nested shape (`disk_config`, `bootloader_config`, `auth_config`, `app_config`).

## Credentials

`user_credentials.json` is **gitignored** (see root `.gitignore`). Only [`user_credentials.example.json`](./user_credentials.example.json) is tracked.

Generate password hashes with:

```sh
mkpasswd -m yescrypt        # for root_enc_password and users[*].enc_password
```

`!encryption-password` (LUKS passphrase) is a plain string. Treat it as the most sensitive value in the file — losing it means losing the disk.

See [`AGENTS.md`](../AGENTS.md) for the full contract.
