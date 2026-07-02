## [2026-07-02] Atlas initialization

### Plan: kubuntu-adaptation-theme-removal

### Key architectural decisions:
- `run_after_` (NOT `run_onchange_`) for de-brand scripts T8-T12 — ensures re-check on every apply, self-heals guard-skipped first runs
- `update-alternatives --set default.plymouth` + `update-initramfs -u` for plymouth revert — NO `plymouth-set-default-theme` on Ubuntu
- apt `.list` files (not deb822 `.sources`) for repo entries
- `sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive` — Ubuntu sudo strips DEBIAN_FRONTEND
- Parse BOTH `Remv` AND `Purg` lines in apt simulation — `apt-get -s purge` prints named packages as `Purg`, collateral as `Remv`
- Separate ubuntu-gated `systemctl mask zramswap.service` — do NOT add to Fedora mask line (masks nonexistent units)
- T10 gate = linux-ubuntu ONLY (not fedora|ubuntu) — Fedora is already unbranded

### Wave structure:
- Wave 1 (parallel): T1, T2, T3, T4, T5, T6
- Wave 2 (parallel after Wave 1): T7 (needs T1), T8, T9, T10 (needs T2), T11, T12
- Wave 3: T13 (needs T1, T6, T7)
- Final: F1-F4 in parallel

### Commit convention:
- Trunk-based on `main`, push to `origin/main` after each commit
- One commit per todo
- Lowercase Conventional Commits: `feat(ubuntu)`, `feat(kde)`, `refactor(bootstrap)`, `docs(adr)`, `docs`

## [2026-07-02 14:18 KST] Task: T2 — generalize KDE render gates to Ubuntu

### Done
- Updated all 14 `.chezmoiscripts/linux-kde/*.sh.tmpl` files.
- Only line 1 changed in each file; bodies and `{{ end -}}` tags stayed byte-identical.
- New gate now renders on Linux Fedora + Ubuntu: `and (eq .chezmoi.os "linux") (or (eq .chezmoi.osRelease.id "fedora") (eq .chezmoi.osRelease.id "ubuntu"))`.

### Verification
- `grep -L 'osRelease.id "ubuntu"' .chezmoiscripts/linux-kde/*.tmpl` returned no output.
- `chezmoi execute-template < .chezmoiscripts/linux-kde/run_onchange_after_config-kde-darkmode.sh.tmpl` rendered successfully on Fedora.
- `git diff --unified=0 -- .chezmoiscripts/linux-kde/*.tmpl` showed one-line-only changes.

### Notes
- Unrelated pre-existing dirty files were present and left untouched:
  - `.chezmoidata/packages.yaml`
  - `dot_config/agent-of-empires/config.toml`
  - `dot_config/opencode/readonly_oh-my-openagent.jsonc`

## [2026-07-02 14:17 KST] Task: T1 — add ubuntu apt parity set to packages.yaml

### Done
- Added `packages.linux.ubuntu:` as a SIBLING of `fedora:` (4-space indent) after line 193.
- 8 keys: aptRepos, corePackages, packages, bareMetalPackages, nvidiaPackages, flatpaks, dotnetTools, directDebs. 60 packages.
- `chezmoi data` exit 0; DELTA count = 3; ubuntu key present; git numstat = 161 added / 0 removed (fedora untouched).

### Findings / gotchas
- `chezmoi data` works WITHOUT `op` auth — it dumps `.chezmoidata` template data only, does not render onepasswordRead secret templates. Safe cheap parse check.
- Working tree had UNRELATED pre-existing dirty files (`dot_config/agent-of-empires/config.toml`, `dot_config/opencode/readonly_oh-my-openagent.jsonc`). Staged ONLY `.chezmoidata/packages.yaml` — do NOT `git add -A` on this repo.
- 3 DELTA markers (no clean apt equivalent): kdotool (build from cargo/drop), keyd (check 26.04 universe else PPA/source), nvidia akmod->ubuntu-drivers+dkms.
- apt repos use one-line `deb [signed-by=/usr/share/keyrings/<id>.gpg] ...` entries (NOT deb822). tailscale/virtualbox/dotnet pin `noble` dist — 26.04 may lag (guarded in T7).
- Package-name deltas vs Fedora: gcc-c++->g++, systemd-devel->libsystemd-dev+libudev-dev, containers-common->golang-github-containers-common, qemu-img->qemu-utils, libguestfs->libguestfs-tools, *-devel->*-dev, lm_sensors->lm-sensors, libappindicator-gtk3-devel->libayatana-appindicator3-dev.

---

## [2026-07-02] Task: T3 — .chezmoiignore audit + ubuntu:26.04 osRelease.id verification

### Audit scope: all 4 .chezmoiignore files
- `.chezmoiignore` (root)
- `dot_config/.chezmoiignore`
- `dot_local/bin/.chezmoiignore`
- `dot_local/share/.chezmoiignore`

### Finding: NO distro-level leaks
All 4 files gate exclusively on `.chezmoi.os` (linux/darwin/windows).
No file references `.chezmoi.osRelease.id`, `fedora`, `ubuntu`, or any distro discriminator.
The ignore layer is fully portable across Linux distros — Kubuntu 26.04 will get
identical deployment to Fedora at the ignore-gate level.

### Container verification: ubuntu:26.04
```
podman run --rm ubuntu:26.04 bash -c '. /etc/os-release; echo "ID=$ID"; ...'
ID=ubuntu
VERSION_ID=26.04
PRETTY_NAME=Ubuntu 26.04 LTS
```
`.chezmoi.osRelease.id` will be `"ubuntu"` on Kubuntu 26.04 — confirmed.
Kubuntu does NOT override the base distro ID in `/etc/os-release`.

### Outcome: no commit needed
Design is sound. Evidence written to `.omo/evidence/task-3-kubuntu-adaptation-theme-removal.txt`.
