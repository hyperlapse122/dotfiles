# Windows host for the VMware guest

This guide sets up a fresh Windows PC to run the `MS-7D91-VM` NixOS guest and to lend it the YubiKey. Windows is not a host this flake builds: nothing here is applied by Nix, and every step runs by hand on Windows. The guest side is declared in `hosts/MS-7D91-VM/` and installed by [fresh installation](install.md).

| Guest | Windows machine |
| --- | --- |
| `MS-7D91-VM` | MSI MS-7D91 (Intel i7-13700F, NVIDIA GeForce RTX 3060) |

The YubiKey stays attached to Windows. Gpg4win's agent owns it, and a small relay on Windows exposes that agent's restricted extra socket over TCP on an isolated VMware network. The guest runs no gpg-agent of its own: its gpg talks to that relay, so Windows and the guest can sign and decrypt with the same card at the same time, and the PIN prompt appears on the Windows desktop.

Before the setup, have:

- Windows 11 with an administrator account;
- one of the three YubiKeys and its PIN;
- a Broadcom account, which the VMware Workstation Pro download requires.

## What the guest expects from Windows

These values are fixed in the repository. Change them only together with `hosts/MS-7D91-VM/default.nix`.

| Item | Value |
| --- | --- |
| Isolated host-only network | a VMware host-only network, subnet `192.168.250.0/24`, DHCP on |
| Windows address on that network | `192.168.250.1` |
| Relay endpoint | `192.168.250.1:4321`, Gpg4win's extra socket only |
| Guest firmware and disk | UEFI with Secure Boot off; one virtual NVMe disk |

The relay's TCP hop has no authentication. The host-only network is the only boundary in front of it, so attach no other VM to that network.

## 1. Encrypt the disk

The guest's root filesystem is not encrypted inside NixOS, and its age identity lives on it. Turn on BitLocker for the drive that will hold the VM (Settings > Privacy & security > Device encryption on Windows 11 Home, or BitLocker on Pro), and keep the recovery key somewhere other than this PC. VMware's own VM encryption is an alternative; one of the two must be on before the guest is installed.

## 2. Install Gpg4win and check the card

Install Gpg4win from [gpg4win.org](https://www.gpg4win.org/), or with winget:

```powershell
winget install --id GnuPG.Gpg4win --exact
```

In a new PowerShell window, import the public key from the repository, trust it, and check that the card is visible. Fetch `keys/signing.asc` from the repository's web view if the checkout is not on this PC yet.

```powershell
gpg --import signing.asc
gpg --edit-key 0x4945855D4F283F05 trust quit   # choose 5, ultimate
gpg --card-status
```

`gpg --card-status` must list the card's serial and the three subkeys. If it cannot see the card, unplug and replug the YubiKey, then run `gpgconf --kill scdaemon` and try again.

Find the extra socket the relay will forward. The file it names holds a TCP port and a nonce, not a Unix socket; the relay reads both.

```powershell
gpgconf --launch gpg-agent
gpgconf --list-dirs agent-extra-socket
```

## 3. Install VMware Workstation Pro

Download VMware Workstation Pro from the Broadcom support portal (it is free for personal use) and install it. `winget show VMware.WorkstationPro` shows whether winget carries the current release; prefer the Broadcom download when it does not.

## 4. Create the isolated network

Open Edit > Virtual Network Editor > Change Settings, then:

1. Add Network, and pick an unused name such as `VMnet2`.
2. Select **Host-only**.
3. Set Subnet IP to `192.168.250.0` and Subnet mask to `255.255.255.0`.
4. Keep **Use local DHCP service** on, and leave **Connect a host virtual adapter** on.
5. Apply.

Windows' adapter on that network takes `192.168.250.1`. Check it with `ipconfig` under "VMware Network Adapter VMnet2". If it took another address, set it to `192.168.250.1` with mask `255.255.255.0` in the adapter's IPv4 properties.

## 5. Install the relay

The relay is [gpg-bridge](https://github.com/BusyJay/gpg-bridge). It has no tagged releases and its last commit is from 2024, so pin the commit you build and test it against the installed Gpg4win before relying on it.

Build it with Rust:

```powershell
winget install --id Rustlang.Rustup --exact
rustup default stable
cargo install --git https://github.com/busyjay/gpg-bridge
```

Rust on Windows links with the MSVC toolchain; if `cargo` reports a missing linker, install the Visual Studio Build Tools with the "Desktop development with C++" workload and run the command again. Without a Rust toolchain, download the latest build artifact from the repository's GitHub Actions instead.

Run it once by hand to check it starts:

```powershell
gpg-bridge --extra 192.168.250.1:4321
```

Pass `--extra-socket <path>` with the path from step 2 if gpg-bridge does not find the extra socket on its own. Stop it with Ctrl+C once the guest check below works.

## 6. Start the relay at logon

Register a scheduled task that starts the agent and the relay when you sign in. Run this in PowerShell as your user, not as administrator:

```powershell
$bridge = (Get-Command gpg-bridge).Source
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -Command `"gpgconf --launch gpg-agent; & '$bridge' --extra 192.168.250.1:4321`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName 'gpg-bridge' -Action $action -Trigger $trigger -Settings $settings
```

The VMware host-only adapter must exist before the relay binds `192.168.250.1`. If the task starts too early after a reboot, it fails and restarts within a minute.

## 7. Allow the relay through the firewall

Allow inbound TCP 4321 only from the isolated network, as administrator:

```powershell
New-NetFirewallRule -DisplayName 'gpg-bridge (VMware host-only)' -Direction Inbound `
  -Protocol TCP -LocalPort 4321 -LocalAddress 192.168.250.1 -RemoteAddress 192.168.250.0/24 -Action Allow
```

Windows may also ask to allow `gpg-bridge.exe` the first time it listens; allow it only for private networks.

## 8. Create the VM

Create a custom VM in Workstation:

- Guest OS: Linux, "Other Linux 6.x kernel 64-bit".
- Firmware: UEFI, with Secure Boot off (VM Settings > Options > Advanced).
- Disk: one new virtual disk of type **NVMe**, at least 128 GB.
- Display: **Accelerate 3D graphics** on.
- Network: the first adapter on **NAT**; add a second adapter on **Custom: VMnet2** (the host-only network from step 4).
- Memory and CPUs: as much as the PC can spare.

Attach the NixOS installation ISO and follow [fresh installation](install.md). Its per-host notes list the disk path the guest expects.

## 9. Check the guest end to end

After the guest's bootstrap install, log in at the VMware console and run:

```sh
ip -4 addr                       # one address on 192.168.250.0/24, one on the NAT network
gpg-connect-agent 'GETINFO version' /bye
```

`gpg-connect-agent` must print Gpg4win's GnuPG version. Then [recover the age identity](install.md#prepare-local-decryption-and-signing-keys): the PIN prompt appears on Windows. After switching to the production output, check signing:

```sh
echo test | gpg --clearsign
```

`gpg --card-status` may fail inside the guest. The extra socket refuses card management, and signing and decryption do not need it.

## 10. SSH into the guest from Windows

The guest accepts only `h82`, authenticated by the YubiKey's authentication subkey. Gpg4win can serve that key to Windows' built-in OpenSSH client. Add this line to `%APPDATA%\gnupg\gpg-agent.conf` and restart the agent:

```text
enable-win32-openssh-support
```

```powershell
gpgconf --kill gpg-agent
gpgconf --launch gpg-agent
ssh-add -L    # lists the card's authentication key
ssh h82@<guest address on 192.168.250.0/24>
```

Stop and disable Windows' own OpenSSH Authentication Agent service if it is running; both use the same named pipe. GnuPG documents this endpoint as experimental, so confirm `ssh-add -L` lists the key before relying on it. The guest's address on the host-only network comes from the `ip -4 addr` check above.

## Verification

Report these checks separately from repository builds; no repository check can run them.

- From a second VM attached only to the NAT network, connecting to `192.168.250.1:4321` fails.
- Signing in the guest works while Windows is also using the card.
- With the `gpg-bridge` task stopped, signing in the guest fails with an agent connection error, and a rebuild in the guest still succeeds.
- After the PC wakes from sleep, signing in the guest works without restarting anything in the guest.

## Retiring the Windows PC

Follow [compromise or decommission of a host](recovery.md#compromise-or-decommission-of-a-host) for `MS-7D91-VM`, then remove the `gpg-bridge` scheduled task and firewall rule.
