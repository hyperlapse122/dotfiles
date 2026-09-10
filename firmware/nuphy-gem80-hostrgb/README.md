# NuPhy Gem80 HostRGB Firmware

Custom QMK firmware for the NuPhy Gem80 keyboard with HostRGB (`0x60`) raw HID control.

## Initial Clone and Git LFS

The first clone of this repository happens before `chezmoi apply`.
At that time, `filter.lfs` is not yet configured in git config, so `dist/*.bin` arrives as LFS pointer text.

After running `chezmoi apply`, fetch the actual binary:

```sh
git lfs pull
```

Do not flash an LFS pointer file. Flashing a pointer file bricks the keyboard.
`gem80-firmware verify` rejects a pointer file before you flash; see
[Verifying the Build Record](#verifying-the-build-record).

## Building

`dist/` already holds a built binary, so most hosts never need to build.
Rebuild only after the keymap or the pinned fork commit changes:

```sh
gem80-firmware build
```

The command is staged by `chezmoi apply` and runs from any directory — every repo
path is baked in when chezmoi renders it. It clones the fork into a scratch tree,
copies `keymap/` into `keyboards/nuphy/gem80/ansi/keymaps/hostrgb/`, builds
`nuphy/gem80/ansi:hostrgb` with rootless Podman and a digest-pinned
`ghcr.io/qmk/qmk_cli` image, writes the result into `dist/`, and deletes the scratch
tree. It prints the `.bin` path.

The fork commit is pinned in `.chezmoidata/firmware.yaml` under
`firmware.gem80.qmkFork`, not in the release lock: the lock refresh job re-resolves
its entries hourly, which would move the SHA away from the committed binary.
Change the fork revision there and rebuild.

`dist/build-info.json` records what produced the binary: the fork source, ref, and
SHA; the make target; the pinned toolchain image digest; the build time; the
binary's size and sha256; and a hash of each file in `keymap/`.

## Verifying the Build Record

Before you flash, confirm the binary in `dist/` still matches the source that
produced it:

```sh
gem80-firmware verify
```

It re-derives every value `build-info.json` records from the current source —
fork source, ref, and SHA; make target; the pinned toolchain image digest; the
binary's size and sha256; and a hash of each file in `keymap/` — and prints `ok`
or `MISMATCH` for each check. It also rejects a Git LFS pointer in place of the
binary. It exits non-zero if any check fails or the binary is a pointer. Do not
flash when it does.

## Flashing

Flashing is effectively irreversible: the only way back is to flash the stock
firmware again. Before you start, download the stock NuPhy firmware and keep it
local, and export your VIA keymap.

1. Switch the keyboard to wired mode, unplug it, then hold `Esc` while plugging
   it back in. This enters the bootloader (DFU mode). `Fn` + `[` held for three
   seconds is a factory reset, not bootloader entry — the two are easy to
   confuse.
2. Confirm the bootloader: `dfu-util -l` should report `Found DFU` for
   `0483:df11`. If it does not, the keyboard did not enter DFU; retry step 1, or
   see [Recovery](#recovery).
3. Run `gem80-firmware verify`. Do not continue if it reports a mismatch.
4. Write the binary:

   ```sh
   dfu-util -a 0 -s 0x08000000:leave -D firmware/nuphy-gem80-hostrgb/dist/nuphy_gem80_ansi_hostrgb.bin
   ```

   Do not disconnect the keyboard while this runs.
5. The device can stay in the `dfuMANIFEST` state after the download finishes,
   with no re-enumeration. Unplug it and plug it back in; the new firmware runs
   after that power cycle.

### Recovery

If the keyboard does not enumerate as a DFU device, or `dfu-util` exits with an
error, remove the Caps Lock keycap and hold the small black button beside its
switch while plugging the keyboard back in. This forces bootloader entry so you
can retry the flash.
