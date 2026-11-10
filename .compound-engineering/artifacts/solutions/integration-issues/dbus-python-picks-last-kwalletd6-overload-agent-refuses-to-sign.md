---
title: dbus-python picks the last overload kwalletd6 declares, so the desktop SSH agent refuses to sign
date: "2026-10-12"
category: integration-issues
module: desktop-ssh agent (scripts/desktop-ssh)
problem_type: integration_issue
component: authentication
symptoms:
  - "ssh prints sign_and_send_pubkey: signing failed for ED25519 \"/nix/store/...-ssh.pub\" from agent: agent refused operation"
  - "The desktop-ssh-agent journal repeats \"primary SSH key unavailable; unlock kdewallet and retry provisioning\" while kdewallet is open"
  - "desktop-ssh-provision.service fails and ~/.ssh/id_ed25519_nix_config is never written"
  - "ERROR:dbus.connection:Unable to set arguments (dbus.String('kdewallet'),) according to signature 'i'"
root_cause: wrong_api
resolution_type: code_fix
severity: high
retire_when: "kwalletd6 stops declaring two isOpen or two close methods on org.kde.KWallet (check with busctl --user introspect org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet), or dbus-python resolves overloads by argument type instead of keeping one signature per method name"
tags: ["kwallet", "kwalletd6", "dbus-python", "d-bus", "introspection", "overload", "desktop-ssh", "ssh-agent", "test-double"]
---

# dbus-python picks the last overload kwalletd6 declares, so the desktop SSH agent refuses to sign

## Problem

kwalletd6 declares two methods named `isOpen` on `org.kde.KWallet`, and two named `close`. dbus-python keeps one signature per method name, so a call that does not name its signature uses the wrong overload. `KWallet.__init__` in `scripts/desktop-ssh` called `isOpen(dbus.String("kdewallet"))`, which dbus-python marshalled as an integer. Every unlock and provisioning run failed, and the desktop SSH agent refused to sign with the host key.

## Symptoms

- `ssh` fails with `sign_and_send_pubkey: signing failed for ED25519 "/nix/store/...-ssh.pub" from agent: agent refused operation`. The path is the declared public key that `home/h82/security/ssh.nix` sets as `IdentityFile`.
- `journalctl --user -u desktop-ssh-agent` repeats `desktop-ssh: primary SSH key unavailable; unlock kdewallet and retry provisioning`, even though `busctl --user call org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet isOpen s kdewallet` returns `true`.
- `desktop-ssh-provision.service` fails with `local SSH provisioning failed; check private file permissions and unlock kdewallet`, and `~/.ssh/id_ed25519_nix_config` does not exist.
- Only the provisioning service's journal shows the real error: `ERROR:dbus.connection:Unable to set arguments (dbus.String('kdewallet'),) according to signature 'i': <class 'TypeError'>: 'dbus.String' object cannot be interpreted as an integer`.

## What Didn't Work

- **Reading the agent's journal.** `Primary.load` runs the `unlock` subcommand with `stderr=subprocess.PIPE` and never reads that output. Every failure becomes the same "unlock kdewallet" message, so the journal sent the investigation toward a locked wallet, and the wallet was open.
- **The existing tests.** The unit test replaced `dbus.Interface` with a `Mock`, and the VM test's fake kwalletd (`tests/desktop-ssh-session.nix`) declares each method once, with `in_signature="s"` for `isOpen`. Neither fake has overloads, so both pass whichever signature the client picks.

What found it was running the agent's own `unlock` step by hand, with a pipe for `--key-fd` and stderr visible:

```python
import os, subprocess, sys
r, w = os.pipe2(os.O_CLOEXEC)
p = subprocess.run([python, tool, "unlock", "--config", config,
                    "--parent-pid", str(os.getpid()), "--key-fd", str(w)],
                   pass_fds=(w,), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
os.close(w)
os.read(r, 64)          # discard: this would be the raw key on success
print(p.stderr.decode())
```

## Solution

Name the overload on every call to a method kwalletd6 overloads:

```python
# Before
if not self.interface.isOpen(dbus.String("kdewallet")):
...
self.interface.close(self.handle, False, self.APP)

# After
if not self.interface.isOpen("kdewallet", signature="s"):
...
self.interface.close(self.handle, False, self.APP, signature="ibs")
```

`close` happened to work, because its handle overload is the last one declared. It names its signature anyway, so a reordering in kwalletd6 cannot break it.

The regression test, `test_wallet_calls_select_the_overload_kwalletd_declares_last` in `tests/test_desktop_ssh.py`, builds the proxy map with dbus-python's real `process_introspection_data`, from XML in kwalletd6's declaration order. Its fake bus passes every call through `dbus.lowlevel.MethodCallMessage(...).append(*args, signature=signature)`, the real marshaller. A call that relies on introspection raises the same `TypeError` the live agent hit.

## Why This Works

`busctl --user introspect org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet` lists `isOpen` with signatures `s` and `i`, and `close` with `sb` and `ibs`. In the XML, `isOpen(s)` comes before `isOpen(i)`, and `close(sb)` before `close(ibs)`.

dbus-python 1.4.0's `_expat_introspect_parser` stores each method's signature under the key `interface + '.' + method` (`self.map[self.in_iface + '.' + self.in_method] = self.sig`), so a second declaration overwrites the first. When a call passes no `signature=`, `_ProxyMethod.__call__` takes the signature from that map. `isOpen("kdewallet")` was therefore marshalled as `i` and raised `TypeError`. The `dbus.String` wrapper does not help, because the signature decides the marshalling.

`TypeError` is not a `dbus.DBusException`, so it got past `KWallet.__init__`'s handlers. It reached `main()`'s catch-all, which prints a generic message, and `Primary.load` reported only a failed unlock. An explicit `signature=` skips the map lookup.

## Prevention

- Pass `signature=` on every dbus-python proxy call to a method the service declares more than once. Check a new D-Bus method with `busctl --user introspect <service> <path> <interface>` before calling it through a proxy.
- A fake D-Bus service or `Mock` interface that declares each method once cannot catch an overload bug. A test of a call to an overloaded method needs the real introspection parser and the real marshaller, as the regression test above uses.
- When the agent reports a failed unlock and the wallet is open, run the `unlock` subcommand by hand as shown above before reasoning from the journal message.

## Related Issues

- [kwriteconfig6 --delete writes a Key[$d] marker that masks kdedefaults](kwriteconfig6-delete-writes-masking-marker-over-cascaded-default.md): another KDE interface whose real behavior a passing check did not model.
- [Fixture state that cannot distinguish a bug from its fix](../best-practices/converged-fixture-state-defeats-nix-check-mutation-testing.md): the same test gap as the fake wallet without overloads.
