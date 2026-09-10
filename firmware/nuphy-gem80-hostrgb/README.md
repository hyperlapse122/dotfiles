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
Pre-flash verification (U6) checks for an LFS pointer before writing to the device.

## Building

`dist/` already holds a built binary, so most hosts never need to build.
Rebuild only after the keymap or the pinned fork commit changes:

```sh
gem80-firmware
```

The command is staged by `chezmoi apply` and runs from any directory — every repo
path is baked in when chezmoi renders it. It clones the fork into a scratch tree,
copies `keymap/` into `keyboards/nuphy/gem80/ansi/keymaps/hostrgb/`, builds
`nuphy/gem80/ansi:hostrgb` with rootless Podman and `ghcr.io/qmk/qmk_cli`, writes
the result into `dist/`, and deletes the scratch tree. It prints the `.bin` path.

The fork commit is pinned in `.chezmoidata/firmware.yaml` under
`firmware.gem80.qmkFork`, not in the release lock: the lock refresh job re-resolves
its entries hourly, which would move the SHA away from the committed binary.
Change the fork revision there and rebuild.

`dist/build-info.json` records what produced the binary — the fork commit, the make
target, the build time, the binary's sha256, and a hash of each of the three keymap
files. Pre-flash verification compares those against the current source and stops
when they disagree.

