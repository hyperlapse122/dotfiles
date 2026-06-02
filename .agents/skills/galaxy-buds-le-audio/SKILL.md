---
name: galaxy-buds-le-audio
description: >
  Pair Samsung Galaxy Buds 4 Pro (and similar Galaxy Buds) for Bluetooth
  LE Audio (BAP unicast, LC3) in stereo on this Fedora/BlueZ host. Use when
  LE Audio earbuds connect only over classic A2DP/HFP, when only one earbud
  plays (mono), or when the "LE Audio" profile never appears in PipeWire.
  Covers the coordinated-set (CSIS) pairing both earbuds need, the live
  bluetoothctl/tmux procedure that beats RPA rotation, and the host config
  prerequisites. Triggers: "pair galaxy buds le audio", "le audio stereo",
  "only left/right earbud", "buds connect as A2DP not LE Audio".
---

# Galaxy Buds 4 Pro — LE Audio (BAP) pairing

Galaxy Buds 4 Pro are a **CSIS coordinated set**: two independent LE Audio
members (left + right earbud), each with its **own** LE bond. Stereo LE Audio
requires **both** members bonded and connected over LE — bonding only one gives
**mono** (one ear). This is the #1 gotcha.

The host config that makes LE Audio possible is already tracked in this repo
(`system/linux/etc/bluetooth/main.conf` → `Experimental = true` +
`KernelExperimental = true`). This skill is the **per-device pairing** runbook,
which is runtime state (lives in `/var/lib/bluetooth/`, not dotfiles).

## Prerequisites (verify once)

```bash
# 1. BlueZ experimental + kernel ISO sockets (shipped by this repo's main.conf).
grep -E "Experimental|KernelExperimental" /etc/bluetooth/main.conf
#   want: Experimental = true   AND   KernelExperimental = true
ps -eo args | grep "[b]luetoothd"            # daemon running (flag not required; main.conf is)

# 2. Controller supports CIS Central (Connected Isochronous Stream).
sudo btmgmt info | tr ' ' '\n' | grep -E "cis-central|cis-peripheral"
#   want both in *current settings* (Intel AX210 has them). If absent → the
#   controller/firmware cannot do unicast LE Audio; stop here.

# 3. LC3 codec stack present.
rpm -q liblc3 && ls /usr/lib64/spa-0.2/bluez5/libspa-codec-bluez5-lc3.so

# 4. bluetoothd registers the LE Audio endpoints (proof the stack is live).
journalctl -b _COMM=bluetoothd | grep -E "MediaEndpointLE/BAP"
#   want: BAPSink/lc3 and BAPSource/lc3 registered.
```

If `main.conf` lacks the keys, install it from the repo and restart:
```bash
sudo install -D -m 0644 ~/dotfiles/system/linux/etc/bluetooth/main.conf /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
```

## Why one-shot pairing fails (read before scripting)

- Over LE the buds advertise under **rotating RPAs** (random addresses) when
  idle, and only under their **identity address** while in **pairing mode**.
- A bare `bluetoothctl connect <public-addr>` brings the device up over
  **BR/EDR** (classic A2DP), *not* LE.
- Separate one-shot `bluetoothctl pair <RPA>` calls can't hold a live scan, so
  the RPA expires between discovery and pair (`Device ... not available`).
- **Solution:** drive ONE persistent `bluetoothctl` session (tmux) with `scan le`
  staying active, and pair both members while they advertise in pairing mode.

## Pairing procedure (stereo, both earbuds)

```bash
# 0. Clear any stale/classic bonds for the buds (use this unit's addresses).
bluetoothctl remove <buds-addr-1> 2>/dev/null
bluetoothctl remove <buds-addr-2> 2>/dev/null

# 1. Put BOTH earbuds in pairing mode: in the case, lid open, hold both
#    touchpads ~3s until the tone. In pairing mode they advertise LE under
#    their identity addresses (no RPA chase).

# 2. Live session in tmux (one D-Bus client, scan stays alive).
tmux new-session -d -s bt -x 220 -y 50 'bluetoothctl'
tmux send-keys -t bt "power on" Enter "agent NoInputNoOutput" Enter "default-agent" Enter "scan le" Enter
sleep 12

# 3. Find both set members by name (strong RSSI = in your hand).
tmux capture-pane -p -t bt -S -300 | grep -iaE "buds" | sort -u
#   Note the two addresses, e.g. 78:C1:1D:D2:77:91 and 78:C1:1D:A8:04:D1.
```

Then pair **both** members in the live session (scan still running):
```bash
tmux send-keys -t bt "pair <member-1>" Enter ; sleep 8
tmux capture-pane -p -t bt -S -40 | grep -iE "successful|fail|confirm|authoriz"

tmux send-keys -t bt "pair <member-2>" Enter ; sleep 10
tmux capture-pane -p -t bt -S -40 | grep -iE "successful|fail|confirm|authoriz"
```

If an `[agent] Authorize service ... (yes/no)` prompt appears, answer it and
trust both members so the set auto-reconnects:
```bash
tmux send-keys -t bt "yes" Enter
tmux send-keys -t bt "trust <member-1>" Enter "trust <member-2>" Enter "scan off" Enter "quit" Enter
tmux kill-session -t bt 2>/dev/null
```

## Verify stereo

```bash
for d in <member-1> <member-2>; do
  echo "[$d]"; bluetoothctl info "$d" | grep -E "LE.Bonded|LE.Connected|Sets.Value.Rank|Trusted"
done
#   want BOTH: LE.Bonded: yes / LE.Connected: yes / Trusted: yes
#   Sets.Value.Rank 0x01 and 0x02 = the two set members.

wpctl status | grep -iE "playback_F"
#   SUCCESS = BOTH "playback_FL [active]" AND "playback_FR [active]".
```

`bluetoothctl info` should show LE Audio UUIDs: PACS `0x1850`, ASCS `0x184e`,
Common Audio `0x1853`, TMAS `0x2b51`, plus `Sets.Key` (the shared SIRK).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Only one ear (mono) | only one set member LE-bonded | pair the other member (repeat the pair step for it) |
| `connect` brings up A2DP, not LE | device has a stale BR/EDR bond that wins | `bluetoothctl remove <addr>`, then LE-pair via the live session |
| `Device ... not available` on pair | RPA rotated before pair fired | use the tmux live session; pair while in pairing mode (identity addr) |
| `br-connection-key-missing` | host/buds key mismatch (buds auto-reconnect classic with old key) | `remove` on host; factory-reset buds (Galaxy Wearable) if it persists |
| LE bonds but no sound / no CIS | kernel/controller CIS path | confirm `cis-central` in `sudo btmgmt info`; capture `sudo btmon` and look for `LE Create CIS` |
| No LE Audio profile at all | BlueZ not experimental / no ISO | check `main.conf` keys + `journalctl -b _COMM=bluetoothd | grep "ISO Socket"` |

Capture evidence when stuck:
```bash
sudo btmon -w /tmp/buds-leaudio.btsnoop &     # then reproduce
journalctl -fu bluetooth
```

## Notes

- Addresses are per-unit. After LE pairing, the device is keyed by its LE
  **identity address** (e.g. `78:C1:1D:D2:77:91`), which can differ from the
  classic BR/EDR public address (`78:C1:1D:A8:04:D1`).
- Profiles available once bonded: `High Fidelity Playback (BAP Sink, LC3)`,
  `High Fidelity Input (BAP Source, LC3)`, `High Fidelity Duplex (BAP
  Source/Sink, LC3)`. Duplex enables the bud mic; Playback-only is best for
  music quality. Switch in KDE → Audio, or `wpctl`.
- Fallback: if LE Audio stereo is flaky, classic **A2DP AAC** gives reliable
  stereo — `bluetoothctl connect <public-addr>` and pick the A2DP profile.
- Trusting both members is what makes the whole set auto-reconnect on power-on.
