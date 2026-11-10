"""Fail when an ELF file under the given store paths has overlapping PT_LOAD segments.

Usage: check_elf_load_segments.py STORE_PATHS_FILE

STORE_PATHS_FILE lists one store path per line, as closureInfo's store-paths
does. patchelf 0.17 and later can rewrite a prebuilt executable's program
headers so a new LOAD segment overlaps an existing one; the dynamic loader
then maps part of the image with the wrong protection and the binary
segfaults on start. A linker never emits overlapping LOAD segments, so any
overlap marks a binary broken this way.
"""

import os
import struct
import sys

PT_LOAD = 1
ET_EXEC = 2
ET_DYN = 3


def load_segments(path):
    """Return the [start, end) virtual ranges of the PT_LOAD segments, or None."""
    with open(path, "rb") as f:
        ident = f.read(16)
        if len(ident) < 16 or ident[:4] != b"\x7fELF":
            return None
        elf_class, data = ident[4], ident[5]
        if elf_class not in (1, 2) or data not in (1, 2):
            return None
        end = "<" if data == 1 else ">"
        if elf_class == 2:
            header = f.read(48)
            if len(header) < 48:
                return None
            e_type, = struct.unpack_from(end + "H", header, 0)
            phoff, = struct.unpack_from(end + "Q", header, 16)
            phentsize, phnum = struct.unpack_from(end + "HH", header, 38)
            entry = end + "IIQQQQQQ"
        else:
            header = f.read(36)
            if len(header) < 36:
                return None
            e_type, = struct.unpack_from(end + "H", header, 0)
            phoff, = struct.unpack_from(end + "I", header, 12)
            phentsize, phnum = struct.unpack_from(end + "HH", header, 26)
            entry = end + "IIIIIIII"
        if e_type not in (ET_EXEC, ET_DYN) or phentsize < struct.calcsize(entry):
            return None
        f.seek(phoff)
        table = f.read(phentsize * phnum)
    if len(table) < phentsize * phnum:
        return None
    segments = []
    for i in range(phnum):
        fields = struct.unpack_from(entry, table, i * phentsize)
        if elf_class == 2:
            p_type, vaddr, memsz = fields[0], fields[3], fields[6]
        else:
            p_type, vaddr, memsz = fields[0], fields[2], fields[5]
        if p_type == PT_LOAD and memsz:
            segments.append((vaddr, vaddr + memsz))
    return segments


def overlaps(segments):
    ordered = sorted(segments)
    return any(a[1] > b[0] for a, b in zip(ordered, ordered[1:]))


def main():
    with open(sys.argv[1]) as f:
        roots = f.read().split()
    scanned = 0
    broken = []
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                path = os.path.join(dirpath, name)
                if os.path.islink(path):
                    continue
                try:
                    segments = load_segments(path)
                except OSError:
                    continue
                if segments is None:
                    continue
                scanned += 1
                if overlaps(segments):
                    broken.append(path)
    if scanned == 0:
        print("no ELF file found, so the check covers nothing", file=sys.stderr)
        return 1
    for path in broken:
        print(f"{path}: PT_LOAD segments overlap", file=sys.stderr)
    print(f"scanned {scanned} ELF files, {len(broken)} with overlapping PT_LOAD segments")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
