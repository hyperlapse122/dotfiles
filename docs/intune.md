# Microsoft Intune on NixOS

The `my.intune.enable` trait enrolls a NixOS host in Microsoft Intune so that conditional access admits it and Microsoft 365 opens in Microsoft Edge. `MS-7D91` enables it on its production output.

Microsoft supports the Intune app only on Ubuntu Desktop 24.04 LTS and 26.04 LTS and on RHEL 9 and 10, and it requires a GNOME desktop. This host runs NixOS with KDE Plasma, so nothing here is a supported configuration, and an update to the Intune app can break enrollment without a change in this repository.

## What the trait installs

- The Intune app (`intune-portal`), its agent and daemon, and the Microsoft identity broker, through the `nixpkgs` `services.intune` module.
- Microsoft Edge in the user environment. Edge signs in through the identity broker, so its session carries the enrolled device's identity. Google Chrome stays the default browser.
- `intune-daemon.socket` and the hourly `intune-agent.timer`. The upstream module leaves both disabled, so without them the app cannot reach the daemon and the device checks in only while the app is open.
- A password quality policy. `passwd` rejects a new password shorter than 12 characters or without a digit, an uppercase letter, a lowercase letter, and a symbol. `/etc/pam.d/common-password` declares the same policy, because the Intune agent reads that Ubuntu path. Both come from one definition in `modules/nixos/services/intune.nix`. Only `passwd` enforces it: the Users page of KDE System Settings sets a password as root without consulting PAM, so change the login password with `passwd`.
- `pam_intune.so` in the PAM stack of every service that authenticates with a password. It is Microsoft's module, it receives the password at each authentication, and it records the password's quality in `/run/intune/<uid>/pwquality` for the agent. Ubuntu installs it the same way.

## The OS identity

Five executables read `/etc/os-release`: `intune-portal`, `intune-agent`, `microsoft-identity-broker`, `microsoft-identity-device-broker`, and `dsreg`. On a host that is not Ubuntu or RHEL they report a distribution the enrollment service rejects.

`packages/intune-ubuntu-identity.nix` starts each of them through `bubblewrap` in its own mount namespace, where an Ubuntu 24.04 file is bound over `/etc/os-release`. Every other process, and `/etc/os-release` itself, still says NixOS. The namespace keeps all of the host's mounts, because the agent judges disk encryption from its own `/proc/mounts`.

The pinned `intune-portal` is Microsoft's build for Ubuntu 26.04 and the pinned identity broker its build for 24.04; the wrapper presents 24.04 to both. To present Ubuntu 26.04 instead, edit the `osRelease` text in `packages/intune-ubuntu-identity.nix` and update the release the `intune` check and the `intune-os-identity` VM test expect.

## Enroll

Only the repository owner runs these steps.

1. Run the production switch (`nr switch`).
2. Log out and log in again with the password. `pam_intune.so` records the password's quality only when a login supplies the password.
3. Open **Microsoft Intune** from the application launcher and sign in with the work account.
4. Review the pre-enrollment screens and select **Next**. Enrollment takes a few minutes.
5. Read the compliance result in the app. After changing anything on the host, select **Refresh** on the device details page to start a new check-in.
6. Open Microsoft Edge, sign in to the work profile, and open Microsoft 365.

The work is verified when the app shows the device as compliant, the device details and `dsreg` report Ubuntu 24.04, and Outlook, Teams, and SharePoint open in Edge. After one more switch and a reboot, the app must still show the device as enrolled without a new sign-in.

## When a check fails

The company's compliance policy decides which checks run, and this repository does not know it. The first enrollment shows the real list.

| The app reports | Response |
| --- | --- |
| The distribution or version is not allowed | The tenant's allowed range excludes 24.04. Present 26.04 as described under [The OS identity](#the-os-identity). |
| The device is not encrypted | The root filesystem is on LUKS2. If the message concerns the exFAT data disk at `/mnt/data`, encrypting or unmounting that disk is a separate decision; this trait changes no disk. |
| The password does not meet the requirements | Change the login password with `passwd` to one that meets the tenant's rules, then log out and in. If the tenant asks for more than the declared policy, raise `passwordPolicy` in `modules/nixos/services/intune.nix`. |
| Microsoft Defender for Endpoint is missing, or a custom compliance script fails | Not covered. `nixpkgs` has no Defender package, and this is follow-up work. |
| Sign-in fails with a keyring or storage error | The identity broker stores tokens in the Secret Service keyring, which KWallet provides here. Microsoft tests only GNOME Keyring; this is follow-up work. |
| The agent or app logs `PeerValidationFailed` | `intune-daemon` expects its clients under `/opt/microsoft/intune/bin`, and on NixOS they run from the Nix store. This is follow-up work. |

A failing check that this table marks as follow-up work does not mean the trait is broken.

## Enrollment state

Removing any of these paths unenrolls the device or signs the account out. No module manages them, and they survive a switch and a reboot.

- `/var/lib/intune`
- `/var/lib/microsoft-identity-device-broker`
- `~/.config/intune`
- `~/.config/microsoft-identity-broker`
- `~/.local/share/intune-portal`
- `~/.local/share/microsoft/identity`
- `~/.local/state/intune`
- The broker's entries in the KWallet Secret Service keyring

Turning the trait off removes the packages, units, PAM rules, and password policy on the next switch and leaves this state in place.

## Checks

- `nix build --no-link .#checks.x86_64-linux.intune` reads the built system: the units, the five wrapped entry points, the PAM files, and Edge.
- `nix build --no-link .#vmChecks.intune-os-identity` boots a VM, starts the device broker, and reads the OS identity and the mounts from inside its namespace. It also logs in and changes a password.

Neither check signs in or enrolls. Enrollment and the compliant verdict are hardware verification.
