# QEMU + OVMF + swtpm test harness

What `archinstall/test-host.sh` does, why each flag matters, and how to debug when the burnable VM misbehaves.

The harness simulates a physical UEFI box with:
- **Secure-Boot-capable OVMF** firmware in Setup Mode (so sbctl can enroll keys from inside the guest)
- **swtpm** software TPM 2.0 (so `systemd-cryptenroll --tpm2` works)
- **virtio-9p** mount of the host config dir at `/mnt/host` and state dir at `/mnt/state`
- **Serial console** redirected to a tmux pane the agent can drive

---

## Required Arch packages

```
qemu-full         # or qemu-base + qemu-system-x86; qemu-desktop pulls GUI bits we don't need
edk2-ovmf         # OVMF firmware + writable VARS template
swtpm             # software TPM emulator
tmux              # session driver
curl              # ISO download
jq                # host-metadata.json parsing for --detect / validation
libarchive        # bsdtar extracts vmlinuz/initramfs from ISO for direct boot
```

Optional:
- `tpm2-tools` if you want to poke the TPM from the host (`tpm2_pcrread`, etc.)
- `virt-firmware` for `virt-fw-vars` (custom OVMF VARS prep — only needed for pre-enrolled MS keys)

---

## OVMF file layout (Arch's `edk2-ovmf`)

Verified files in current `edk2-ovmf`:

```
/usr/share/edk2/x64/OVMF_CODE.4m.fd           # firmware code (no SB)
/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd   # firmware code (SB-capable)
/usr/share/edk2/x64/OVMF_VARS.4m.fd           # NVRAM template (blank, Setup Mode)
```

There is **no `OVMF_VARS.secboot.4m.fd`** in Arch — i.e., no pre-enrolled Microsoft KEK/db. The script picks `OVMF_CODE.secboot.4m.fd` + writable copy of `OVMF_VARS.4m.fd`. That puts the firmware in Setup Mode, exactly what we want for sbctl key enrollment.

If you ever need pre-enrolled MS keys (testing shim/grub style boot of unsigned ISOs), generate them with `virt-fw-vars`:

```bash
virt-fw-vars \
  --input /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  --output OVMF_VARS.secboot.fd \
  --secure-boot \
  --enroll-redhat
```

The harness doesn't do this — Arch ISO is unsigned anyway, so Setup Mode is the only path that boots it.

---

## Other distros' OVMF paths

`discover_ovmf()` in `test-host.sh` checks each:

| Distro | CODE | VARS template |
|---|---|---|
| Arch | `/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd` | `/usr/share/edk2/x64/OVMF_VARS.4m.fd` |
| Older Arch | `/usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd` | `/usr/share/edk2-ovmf/x64/OVMF_VARS.fd` |
| Debian/Ubuntu (`ovmf` package) | `/usr/share/OVMF/OVMF_CODE.secboot.fd` | `/usr/share/OVMF/OVMF_VARS.fd` |
| Fedora (`edk2-ovmf` package) | `/usr/share/OVMF/x64/OVMF_CODE.secboot.4m.fd` | `/usr/share/OVMF/x64/OVMF_VARS.4m.fd` |
| openSUSE | `/usr/share/qemu/ovmf-x86_64-smm-ms-code.bin` | `/usr/share/qemu/ovmf-x86_64-smm-ms-vars.bin` |

If your distro stores them elsewhere, add a path to the candidate arrays in `discover_ovmf()`.

---

## swtpm setup

The harness uses `swtpm_setup` first (creates EK + platform cert, "firmware-realistic" TPM):

```bash
swtpm_setup --tpm2 --tpmstate "$STATE/tpm" \
  --create-ek-cert --create-platform-cert --allow-signing \
  --overwrite --pcr-banks -
```

Then runs swtpm in socket-daemon mode:

```bash
swtpm socket --tpm2 \
  --tpmstate "dir=$STATE/tpm,mode=0600" \
  --ctrl "type=unixio,path=$STATE/tpm/swtpm-sock" \
  --pid "file=$STATE/tpm/swtpm.pid" \
  --daemon
```

QEMU consumes the socket via:

```
-chardev socket,id=chrtpm,path=$STATE/tpm/swtpm-sock
-tpmdev emulator,id=tpm0,chardev=chrtpm
-device tpm-tis,tpmdev=tpm0
```

In the guest:

```bash
ls /sys/class/tpm/                # tpm0 should appear
tpm2_pcrread                      # should respond
systemd-analyze has-tpm2          # should print "yes"
systemd-cryptenroll --tpm2-device=list
```

**Burnable model**: the swtpm state lives in `$STATE/tpm/`. Each `test-host.sh` invocation creates a fresh `$STATE` (timestamped under `~/.cache/archinstall-host/state/`), so each test run gets a brand-new TPM with no PCR history. PCR 7 starts fresh on every test, which is exactly what you want for repeatable testing.

---

## QEMU command (annotated)

```bash
qemu-system-x86_64 \
  -enable-kvm                                          # KVM acceleration; drop with --no-kvm if /dev/kvm absent
  -cpu host                                            # passthrough host CPU features (needed for VT-x/AMD-V passthrough; correctly exposes RDRAND etc.)
  -smp 4                                               # 4 vCPUs; tune via --smp
  -m 4G                                                # 4 GB RAM; tune via --ram
  -machine q35,smm=on                                  # q35 chipset; SMM is REQUIRED for Secure Boot (firmware needs SMM-protected NVRAM)
  -global driver=cfi.pflash01,property=secure,value=on # marks NVRAM (pflash) as SMM-protected; without this, Secure Boot variables are writable from non-SMM code (defeats the point)
  -drive if=pflash,format=raw,readonly=on,file=$CODE   # firmware CODE (read-only, system-wide path)
  -drive if=pflash,format=raw,file=$VARS               # firmware VARS (writable per-VM copy)
  -drive file=$STATE/disk.qcow2,if=none,id=hd0,format=qcow2
  -device nvme,drive=hd0,serial=test-host-$HOSTNAME    # installed target looks like a physical NVMe drive
  -drive file=$ISO,if=none,id=cd0,format=raw,readonly=on,media=cdrom
  -device ide-cd,drive=cd0,bus=ide.0                   # ISO remains visible to archiso initramfs
  -netdev user,id=net0,hostfwd=tcp::2222-:22           # user-mode net + port-fwd guest:22 → host:2222
  -device virtio-net-pci,netdev=net0
  -chardev socket,id=chrtpm,path=$STATE/tpm/swtpm-sock # swtpm socket
  -tpmdev emulator,id=tpm0,chardev=chrtpm
  -device tpm-tis,tpmdev=tpm0                          # TPM device exposed to guest as tpm0
  -virtfs local,path=$HOST_DIR,mount_tag=host0,security_model=none,id=host0,readonly=on  # 9p mount of archinstall/<hostname>/
  -virtfs local,path=$STATE,mount_tag=state0,security_model=none,id=state0               # merged config + logs
  -display none                                        # no GUI
  -serial mon:stdio                                    # serial console + qemu monitor merged on stdio (= the tmux pane)
  -kernel $STATE/arch/boot/x86_64/vmlinuz-linux        # direct kernel boot for deterministic serial output
  -initrd $STATE/arch/boot/x86_64/initramfs-linux.img
  -append "archisobasedir=arch archisolabel=$ARCHISO_LABEL console=ttyS0,115200 cow_spacesize=2G"
  -name archinstall-host-<hostname>                    # human-readable VM name
```

Direct kernel boot is for the **live ISO only**. It bypasses the GRUB menu timer and guarantees the Arch installer reaches ttyS0. After a successful install, do NOT reboot the same QEMU process: `-kernel`/`-initrd` would boot the live ISO again. Power off, then relaunch QEMU against the same qcow2 + OVMF VARS + TPM state with no ISO and no `-kernel`/`-initrd` so UEFI loads systemd-boot from the installed ESP. `test-host.sh --boot-installed <hostname>` performs that relaunch.

References:
- archiso's [`run_archiso.sh`](https://github.com/archlinux/archiso/blob/52bf735fc434aa0bd9d04433dcb70a1313856a1e/scripts/run_archiso.sh#L138-L150) for the canonical SMM + pflash combo
- sbctl's [`integration_test.go`](https://github.com/Foxboron/sbctl/blob/1b913e78d38cd0634082fd95e99728cbdecbb0a5/tests/integration_test.go#L69-L79) for the "copy VARS to writable location per VM" pattern

---

## Driving the install from tmux

`test-host.sh` starts the tmux session and immediately sends the QEMU cmdline. Attach:

```bash
tmux attach -t archinstall-host-<hostname>
```

You'll land on the QEMU stdio (= serial console + qemu monitor merged). With direct kernel boot, there is no GRUB step. The live ISO reaches `archiso login:` on ttyS0.

The Arch live ISO autologins root on tty1, **not** ttyS0. On serial, type `root` and press Enter; the live ISO root password is empty.

Once the live root prompt appears:

```bash
# inside the guest
mkdir -p /mnt/host /mnt/state
mount -t 9p -o trans=virtio,version=9p2000.L,ro host0 /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L     state0 /mnt/state
ls /mnt/host
# user_configuration.json  user_credentials.json  host-metadata.json  ...

jq -s '.[0] * .[1]' /mnt/host/user_configuration.json /mnt/state/test-disk-config.json \
  > /mnt/state/merged-config.json

archinstall \
  --config /mnt/state/merged-config.json \
  --creds  /mnt/host/user_credentials.json \
  --silent

# wait for archinstall to complete + custom_commands to run
reboot
```

After `archinstall` mounts the target root on `/mnt`, the original `/mnt/host` and `/mnt/state` 9p mounts are buried under the new root mount. They still exist in the mount namespace but are no longer path-accessible. Do not rely on `/mnt/host` from `custom_commands` or post-failure recovery; `custom_commands` run inside `arch-chroot /mnt` and cannot see live-ISO-only 9p mounts anyway.

If `custom_commands` clone this repo and then install files from the clone, local-only files will not exist in the VM. Commit/push referenced scripts and services before a production-faithful `--drive` test, or recover explicitly by pasting/copying the files into `/mnt` before reboot.

To boot the installed system after the installer, stop the live-ISO QEMU process and relaunch without `-kernel`/`-initrd`/ISO. Use:

```bash
archinstall/test-host.sh --boot-installed <hostname>
```

If systemd-boot renders but does not accept serial Enter, inject keys through the QEMU monitor (`Ctrl-a c`, then `sendkey ret`) or make the installed loader fully unattended by setting loader timeout/kernel command line during install. The harness adds a USB keyboard on installed boots so monitor `sendkey` has a real keyboard device to target.

---

## Verification inside the installed guest

```bash
# Secure Boot
bootctl status
sbctl status

# TPM2 enrollment
systemd-cryptenroll --tpm2-device=list
cryptsetup luksDump /dev/<root-luks-device> | grep tpm2

# First-boot service ran cleanly
systemctl status <hostname>-secureboot-tpm-enroll.service
journalctl -u <hostname>-secureboot-tpm-enroll.service
```

If the first-boot service is still pending, run it manually:

```bash
sudo systemctl start <hostname>-secureboot-tpm-enroll.service
```

---

## Switching to a screenshot-able display

If you need to see firmware UI (rare — sbctl from inside the guest covers most needs), switch to VNC:

In `test-host.sh`, change `-display none -serial mon:stdio` to:

```
-display none
-vnc unix:$STATE/vnc.sock
-serial file:$STATE/serial.log
-monitor unix:$STATE/monitor.sock,server,nowait
```

Then on the host:

```bash
gvncviewer "unix=$STATE/vnc.sock"
# or screenshot via QEMU monitor:
echo 'screendump $STATE/screen.ppm' | socat - "UNIX:$STATE/monitor.sock"
```

---

## 9p notes

The harness mounts `archinstall/<hostname>/` as **read-only** 9p (`readonly=on` in the `-virtfs` line). This prevents accidental writes from the guest to your repo. The guest mounts as:

```bash
mount -t 9p -o trans=virtio,ro host0 /mnt/host
```

If you need to write back from the guest to the host (e.g. capturing `archinstall --dry-run` output), drop `readonly=on` from the `-virtfs` line and remount `-o trans=virtio,rw`.

Discovery from t14-gen2 validation: mounting the 9p shares under `/mnt` is convenient before `archinstall` starts, but `archinstall` later mounts the target root at `/mnt` and buries those paths. That is fine for passing config/creds into `archinstall`; it is not fine for late custom-command file access. Late-stage files must come from the installed filesystem, a remote clone, or an explicit recovery paste/copy.

---

## Cleanup model — what "burnable" means

Everything per-VM lives under `$STATE = ~/.cache/archinstall-host/state/<hostname>-<timestamp>/`:

```
$STATE/
├── disk.qcow2          # install target
├── OVMF_VARS.fd        # writable firmware NVRAM
└── tpm/
    ├── tpm2-00.permall # swtpm persistent state
    ├── swtpm-sock      # swtpm control socket
    └── swtpm.pid       # swtpm PID
```

Plus session metadata at `~/.cache/archinstall-host/sessions/<hostname>.env` (so `--cleanup` can find everything).

`test-host.sh --cleanup <hostname>` does:

1. `tmux kill-session -t archinstall-host-<hostname>` → kills QEMU
2. `kill $SWTPM_PID` → kills the software TPM
3. `rm -rf $STATE` (unless `--keep` was passed at provision time)
4. `rm $SESSIONS_DIR/<hostname>.env`

Pass `--keep` to `provision` if you want to inspect disk/VARS/TPM state after the test for forensics. You'll need to clean up manually with `rm -rf $STATE`.

---

## Test runtime expectations

| Phase | Time |
|---|---|
| `test-host.sh provision` (first run, ISO download) | 2–10 min depending on mirror |
| `test-host.sh provision` (cached ISO) | <10 sec |
| Boot ISO to live shell (KVM) | 30–60 sec |
| `archinstall --silent` package install | 5–20 min depending on package count + mirror |
| `custom_commands` execution | 30 sec – 5 min depending on inline work |
| Reboot + first-boot service | 30 sec |
| Per-test total (cached ISO, KVM, ~250 packages) | ~10–25 min |

Without KVM (TCG fallback), expect 5–10x slower. Don't run the full test suite without KVM unless you have to.

---

## Troubleshooting checklist

| Symptom | Check |
|---|---|
| QEMU exits immediately | `bash -x test-host.sh` to see what flag is malformed; `qemu-system-x86_64 --version` |
| `OVMF Secure Boot CODE firmware not found` | `pacman -Ql edk2-ovmf \| grep secboot` and add the right path to `discover_ovmf()` |
| swtpm fails to start | `swtpm socket --tpm2 ...` manually; check `$STATE/tpm/` perms; `swtpm --version` (need 0.7+) |
| `/dev/kvm: permission denied` | `usermod -aG kvm $USER` + log out / in; or run with `sudo`; or `--no-kvm` |
| `9p: virtfs failed: function not implemented` | Kernel missing 9p — `modprobe 9p 9pnet 9pnet_virtio` on host (not common) |
| Serial console blank after boot | ISO grub entry didn't include `console=ttyS0,115200` — pick the "serial console" menu entry, or hit `e` and edit |
| Guest can't reach internet | `--netdev user` may be blocked by host firewall — try `nmap -p 80 google.com` from guest; check host iptables |
| `pacstrap` fails after long downloads with 404 / `Operation too slow` | Mirror list is stale or too broad. Probe a current package URL on every mirror before retrying; keep only synced HTTPS mirrors. Country-region mirror lists can include stale endpoints. |
| `archinstall: --creds: file not found` | The 9p mount is read-only and `user_credentials.json` is missing on host; create it locally first |
| `install: cannot stat '/home/<user>/dotfiles/archinstall/<host>/...'` in custom_commands | The file exists locally but not in the repo clone inside the VM. Commit/push it before re-testing, or recover manually by copying/pasting it into `/mnt` before reboot. |
| After install, reboot returns to `archiso login:` | You rebooted the direct-kernel live ISO QEMU process. Relaunch with `--boot-installed <host>` so UEFI boots the qcow2 disk. |
| systemd-boot menu appears but Enter does nothing | Serial stdin may not be a firmware keyboard. Use QEMU monitor `sendkey ret` (with USB keyboard device) or set loader timeout/kernel cmdline during install. |
| TPM2 enrollment hangs | swtpm dead (`kill -0 $SWTPM_PID`); check `$STATE/tpm/swtpm.pid` is alive |
| `sbctl enroll-keys` fails inside guest | Firmware must be in Setup Mode — check it's the `OVMF_VARS.4m.fd` (not `.secboot.4m.fd`) copy that was used |
