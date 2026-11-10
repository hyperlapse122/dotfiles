# Fresh installation

The supported hosts are the directories under `hosts/`. In the commands below, replace `<host>` with the target machine's directory name; `nix eval .#nixosConfigurations --apply builtins.attrNames` lists every configuration. A machine without a host directory needs [adding a host](adding-a-host.md) first. This guide installs NixOS; a machine that keeps its own Linux distribution follows [non-NixOS hosts](adding-a-host.md#non-nixos-hosts) instead, and a Mac follows [macOS hosts](macos.md). Notes that apply to one machine only are under [per-host notes](#per-host-notes).

This procedure erases the existing operating system and data on the target disk. Do not repeat it for routine configuration changes.

## Prepare before erasing the disk

1. Complete [bootstrap age preparation](adding-a-host.md#create-bootstrap-age-material) and token encryption (`../secrets/README.md`) on the existing system. Store the public GPG key, encrypted tokens, and per-host age identity encrypted for the YubiKey under `secrets/bootstrap/<host>/` in the repository. Verify decryption.
2. Push repository changes to the remote and confirm that the installation environment can clone it over HTTPS without SSH authentication. You can also keep a clone on separate media.
3. Prepare a NixOS x86_64 installation image.

The root filesystem is not encrypted inside NixOS, so the local age identity is only as safe as the disk that holds it. Protect that disk outside NixOS, for example with BitLocker on the Windows host or VMware's VM encryption.

If the YubiKey is the only recovery method, losing it prevents recovery of the encrypted age identity. Prepare another GPG recipient or an offline recovery copy before erasing the disk if needed.

## Check the disk from the installation media

Run the following commands in the installation media's terminal. Check network access and fetch the repository.

```sh
git clone https://github.com/hyperlapse122/nix-config.git
cd nix-config
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
```

Confirm that the `/dev/disk/by-id/` path declared as `device` in `hosts/<host>/disko.nix` matches the target disk in the `lsblk` output. The per-host notes list each machine's expected path. Do not select the target solely by its enumeration as `/dev/nvme0n1`.

## Initialize the disk and install the bootstrap configuration

The disko command below **erases the entire target disk**. Run it only when the target path in the file matches the `lsblk` output. Use the disko version pinned in the lock file.

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run .#disko -- \
  --mode disko hosts/<host>/disko.nix
sudo nixos-install --flake .#<host>-bootstrap --no-root-passwd
sudo nixos-enter --root /mnt -c 'passwd h82'
```

The layout consists of a 2 GiB ESP and a Btrfs partition with root/home/nix/log/swap subvolumes. The `/swap` subvolume holds a swapfile; no hibernation resume offset is configured. Disks other than the one in `disko.nix` are not touched. systemd-boot is the boot loader on both outputs; Secure Boot is not used.

Reboot and verify Plasma login and `sudo -v`. The bootstrap configuration does not require real token decryption.

## Prepare local decryption and signing keys

On the installed NixOS, fetch the repository again over HTTPS and recover the age identity. This recovery is needed only for initial installation or recovery. See `../secrets/README.md` for the pipeline it runs and the boundary it preserves. A host whose GPG goes through a remote agent (see [per-host notes](#per-host-notes)) needs that agent reachable first: the bootstrap output already runs the relay socket, and the PIN prompt appears where the card is attached.

```sh
./scripts/recover-age-identity
```

On the installed system the helper resolves the host from its hostname, which `mkHost` sets to `<host>`. Pass `--host <host>` when running it anywhere else.

On a host with a local card, register this card's PIN now so later Git signing does not prompt for it again. Three cards carry the same signing key under separate PINs, so Secret Service stores one `gnupg-card-pin` entry per normalized serial and discards only a rejected card's entry (in 1Password > Settings > Developer, also enable the SSH agent and "Integrate with 1Password CLI" once). Enter the PIN at the command's prompt, not in its arguments or shell history. Skip this on a host that relays to a remote agent; the remote side owns the PIN.

```sh
nix develop
card_serial='<normalized serial from gpg --card-status>'
secret-tool store --label='OpenPGP card PIN' service gnupg-card-pin username "$card_serial"
unset card_serial
```

Then switch to the production output. The rebuild deploys user settings and CLI authentication files together.

```sh
sudo nixos-rebuild switch --flake .#<host>
```

Confirm hardware and VM behavior separately from repository builds, and follow the [recovery guide](recovery.md) for later failures.

## Per-host notes

### MS-7D91-VM

NixOS as a VMware Workstation guest on the MS-7D91 PC (Intel i7-13700F, NVIDIA GeForce RTX 3060), which runs Windows. Windows owns the YubiKey; the guest uses Windows' Gpg4win agent for every GPG operation. [Windows host](windows.md) sets up the Windows side, including the VM itself; the guest expects the following.

- The VM uses UEFI firmware with Secure Boot off, a virtual NVMe disk, and 3D acceleration. `hosts/MS-7D91-VM/disko.nix` expects that disk at `/dev/disk/by-id/nvme-VMware_Virtual_NVMe_Disk_VMware_NVME_0000`; confirm it in the `lsblk` step.
- The VM has two network adapters: one on VMware's NAT network for internet access, and one on an isolated host-only network with the subnet `192.168.250.0/24`, where Windows has `192.168.250.1`. Attach no other VM to that host-only network: it is the only boundary in front of the relay.
- A relay on Windows exposes Gpg4win's restricted extra socket, and only that socket, as plain TCP on `192.168.250.1:4321`, listening only on the host-only network. `my.gpgAgentRelay.endpoint` in `hosts/MS-7D91-VM/default.nix` names that address. The guest runs no local gpg-agent, so the PIN prompt and its caching come from Gpg4win.
- `sshd` accepts only `h82`, authenticated by the YubiKey's authentication subkey. Windows reaches it at the guest's host-only address through an SSH client that uses the card, such as Gpg4win's SSH support.
- Tailscale, Proton VPN, WiFiman, and printing are off. Without Tailscale, only the Windows host reaches the guest.
