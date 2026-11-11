"""Drive antigravity-acp-repack against fixture archives.

Each fixture is a larger file with a stored zip inside it, shaped like the
embedded archive of the runtime launcher: entries in name order, files the
launcher maps at page-aligned data offsets behind zero-byte gaps, and spare
zero bytes before the central directory. The module text is invented. The
tool runs as a subprocess, so the tests see only its command line, its exit
status, and the bytes it writes.
"""

import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib
from io import BytesIO
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/antigravity-acp-repack"

PAGE = 512
TARGET = "fakepkg/inner/shipped.py"
FUNCTION = "greet"
OVERLAY_NAME = "shipped_overlay.py"
OVERLAY_ENTRY = "fakepkg/inner/shipped_overlay.py"
CACHE = "fakepkg/inner/__pycache__/shipped.cpython-314.pyc"
OTHER_CACHE = "fakepkg/inner/__pycache__/other.cpython-314.pyc"
SIBLING_CACHE = "fakepkg/__pycache__/shipped.cpython-314.pyc"
ALIGNED = "fakepkg/zdata.bin"

SHIPPED = b'def greet(name):\n    return "hello " + name\n'
OVERLAY = b"""from . import shipped

_greet = shipped.greet


def greet(name):
    return _greet(name).upper()


shipped.greet = greet
"""
IMPORT_LINE = b"from fakepkg.inner import shipped_overlay\n"
ZDATA = bytes(range(256)) * 3

PREFIX = b"stand-in launcher code " * 37
SUFFIX = b"stand-in trailing section " * 11


def local_entry(name, data, offset):
    encoded = name.encode()
    header = struct.pack(
        "<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0x21, zlib.crc32(data), len(data), len(data), len(encoded), 0
    )
    central = struct.pack(
        "<IHHHHHHIIIHHHHHII",
        0x02014B50, (3 << 8) | 20, 20, 0, 0, 0, 0x21, zlib.crc32(data), len(data), len(data),
        len(encoded), 0, 0, 0, 0, 0o100644 << 16, offset,
    )  # fmt: skip
    return header + encoded + data, central + encoded


def make_zip(entries, base, spare):
    """A stored zip whose aligned entries sit on PAGE inside a file that starts it at base."""
    body = bytearray()
    directory = bytearray()
    for name, data, aligned in sorted(entries):
        if aligned:
            body += b"\0" * (-(base + len(body) + 30 + len(name.encode())) % PAGE)
        local, central = local_entry(name, data, len(body))
        body += local
        directory += central
    body += b"\0" * spare
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(directory), len(body), 0)
    return bytes(body + directory + end)


def entries(aligned=True, target=SHIPPED):
    rows = [
        ("fakepkg/__init__.py", b"", False),
        (SIBLING_CACHE, b"sibling bytecode " * 4, False),
        ("fakepkg/inner/__init__.py", b"", False),
        (OTHER_CACHE, b"other bytecode " * 4, False),
        (CACHE, b"stale bytecode of shipped " * 8, False),
        (TARGET, target, False),
    ]
    if aligned:
        rows.append((ALIGNED, ZDATA, True))
    return rows


def make_file(rows=None, spare=3000, suffix=SUFFIX, decoys=1):
    """A file holding decoy zips, then the archive; returns bytes, base, and archive length."""
    rows = entries() if rows is None else rows
    blob = PREFIX
    for number in range(decoys):
        blob += make_zip([(f"decoy{number}/thing.py", b"print('decoy')\n", False)], len(blob), 0)
        blob += PREFIX
    base = len(blob)
    archive = make_zip(rows, base, spare)
    return blob + archive + suffix, base, len(archive)


def zip_of(data, base, length):
    return zipfile.ZipFile(BytesIO(data[base : base + length]))


def data_offset(data, base, zip_file, name):
    info = zip_file.getinfo(name)
    start = base + info.header_offset
    name_length, extra_length = struct.unpack("<HH", data[start + 26 : start + 30])
    return start + 30 + name_length + extra_length


class RepackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.overlay = self.dir / OVERLAY_NAME
        self.overlay.write_bytes(OVERLAY)

    def write_input(self, *args, **kwargs):
        data, base, length = make_file(*args, **kwargs)
        path = self.dir / "input.par"
        path.write_bytes(data)
        path.chmod(0o755)
        return path, data, base, length

    def run_tool(self, *arguments, function=FUNCTION, target=TARGET, overlay=None):
        command = [
            sys.executable, str(SCRIPT), "--page-size", str(PAGE),
            "--extend", target, function, str(overlay or self.overlay),
            *arguments,
        ]  # fmt: skip
        return subprocess.run(command, capture_output=True, text=True)

    def rebuild(self, source, **kwargs):
        output = self.dir / "output.par"
        result = self.run_tool(str(source), str(output), **kwargs)
        return result, output

    def test_rebuild_keeps_length_and_bytes_outside_the_archive(self):
        source, data, base, length = self.write_input()
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        built = output.read_bytes()
        self.assertEqual(len(built), len(data))
        self.assertEqual(built[:base], data[:base])
        self.assertEqual(built[base + length :], data[base + length :])
        self.assertEqual(output.stat().st_mode & 0o777, 0o755)
        archive = zip_of(built, base, length)
        self.assertIsNone(archive.testzip())
        self.assertEqual(
            [info.filename for info in archive.infolist()],
            sorted(name for name in [row[0] for row in entries()] + [OVERLAY_ENTRY] if name != CACHE),
        )
        self.assertTrue(all(info.compress_type == zipfile.ZIP_STORED for info in archive.infolist()))

    def test_target_gains_import_and_overlay_replaces_its_bytecode(self):
        source, data, base, length = self.write_input()
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = zip_of(output.read_bytes(), base, length)
        self.assertEqual(archive.read(TARGET), SHIPPED + IMPORT_LINE)
        self.assertEqual(archive.read(OVERLAY_ENTRY), OVERLAY)
        names = archive.namelist()
        self.assertNotIn(CACHE, names)
        self.assertIn(OTHER_CACHE, names)
        self.assertIn(SIBLING_CACHE, names)

    def test_import_line_follows_a_target_that_lacks_a_final_newline(self):
        source, data, base, length = self.write_input(rows=entries(target=SHIPPED.rstrip(b"\n")))
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(zip_of(output.read_bytes(), base, length).read(TARGET), SHIPPED + IMPORT_LINE)

    def test_aligned_entry_without_so_suffix_stays_aligned_after_an_earlier_entry_grows(self):
        source, data, base, length = self.write_input()
        before = zip_of(data, base, length)
        self.assertEqual(data_offset(data, base, before, ALIGNED) % PAGE, 0)
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        built = output.read_bytes()
        archive = zip_of(built, base, length)
        offset = data_offset(built, base, archive, ALIGNED)
        self.assertEqual(offset % PAGE, 0)
        self.assertEqual(built[offset : offset + len(ZDATA)], ZDATA)

    def test_rebuilt_target_runs_the_overlay_when_imported_from_the_archive(self):
        # The launcher reads the zip from the end of its file, so no trailing bytes here.
        source, data, base, length = self.write_input(suffix=b"")
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        probe = subprocess.run(
            [
                sys.executable, "-B", "-c",
                "import sys; sys.path.insert(0, sys.argv[1]);"
                "from fakepkg.inner import shipped; print(shipped.greet('world'))",
                str(output),
            ],
            capture_output=True, text=True,
        )  # fmt: skip
        self.assertEqual(probe.returncode, 0, probe.stderr)
        self.assertEqual(probe.stdout.strip(), "HELLO WORLD")

    def test_target_without_the_named_function_fails_and_writes_nothing(self):
        source, *_ = self.write_input()
        result, output = self.rebuild(source, function="missing_function")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TARGET, result.stderr)
        self.assertIn("missing_function", result.stderr)
        self.assertFalse(output.exists())

    def test_function_defined_only_inside_a_class_is_not_module_level(self):
        nested = b"class Holder:\n    def greet(self, name):\n        return name\n"
        source, *_ = self.write_input(rows=entries(target=nested))
        result, output = self.rebuild(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TARGET, result.stderr)
        self.assertFalse(output.exists())

    def test_missing_target_module_fails_without_output(self):
        source, *_ = self.write_input()
        result, output = self.rebuild(source, target="fakepkg/inner/absent.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absent.py", result.stderr)
        self.assertFalse(output.exists())

    def test_deflated_entry_fails_naming_the_entry(self):
        archive = BytesIO()
        with zipfile.ZipFile(archive, "w") as zip_file:
            for name, payload, _ in entries():
                zip_file.writestr(
                    zipfile.ZipInfo(name),
                    payload,
                    zipfile.ZIP_DEFLATED if name == OTHER_CACHE else zipfile.ZIP_STORED,
                )
        source = self.dir / "deflated.par"
        source.write_bytes(PREFIX + archive.getvalue())
        result, output = self.rebuild(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(OTHER_CACHE, result.stderr)
        self.assertIn("not a plain stored entry", result.stderr)
        self.assertFalse(output.exists())

    def test_overlay_larger_than_the_spare_space_states_the_exact_shortfall(self):
        source, data, base, length = self.write_input(rows=entries(aligned=False))
        big = self.dir / OVERLAY_NAME
        big.write_bytes(OVERLAY + b"#" * 8000 + b"\n")
        result, output = self.rebuild(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TARGET, result.stderr)
        shortfall = int(re.search(r"needs (\d+) more bytes", result.stderr).group(1))
        self.assertGreater(shortfall, 0)
        self.assertFalse(output.exists())
        # Dropping exactly that many bytes from the overlay makes it fit with nothing to spare.
        big.write_bytes(OVERLAY + b"#" * (8000 - shortfall) + b"\n")
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(output.read_bytes()), len(data))
        big.write_bytes(OVERLAY + b"#" * (8000 - shortfall + 1) + b"\n")
        result, _ = self.rebuild(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"needs 1 more bytes")

    def test_file_with_two_archives_picks_the_one_that_lists_the_target(self):
        source, data, base, length = self.write_input(decoys=2)
        result, output = self.rebuild(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        built = output.read_bytes()
        self.assertEqual(zip_of(built, base, length).read(TARGET), SHIPPED + IMPORT_LINE)
        # Both decoy archives are untouched.
        self.assertEqual(built[:base], data[:base])

    def test_file_with_two_archives_that_list_the_target_is_refused_and_writes_nothing(self):
        first = make_zip(entries(), len(PREFIX), 0)
        second_base = len(PREFIX) + len(first) + len(PREFIX)
        source = self.dir / "twice.par"
        source.write_bytes(PREFIX + first + PREFIX + make_zip(entries(), second_base, 0) + SUFFIX)
        result, output = self.rebuild(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"more than one zip archive in the file lists {TARGET}", result.stderr)
        self.assertFalse(output.exists())

    def test_file_with_no_archive_that_lists_the_target_fails(self):
        source = self.dir / "decoy-only.par"
        source.write_bytes(PREFIX + make_zip([("decoy/thing.py", b"x = 1\n", False)], len(PREFIX), 0) + SUFFIX)
        result, output = self.rebuild(source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TARGET, result.stderr)
        self.assertFalse(output.exists())

    def test_check_succeeds_on_a_rebuildable_file_and_writes_nothing(self):
        source, data, *_ = self.write_input()
        before = sorted(path.name for path in self.dir.iterdir())
        result = self.run_tool("--check", str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_bytes(), data)
        self.assertEqual(sorted(path.name for path in self.dir.iterdir()), before)

    def test_check_fails_on_a_file_the_rebuild_cannot_fit(self):
        source, *_ = self.write_input(rows=entries(aligned=False))
        (self.dir / OVERLAY_NAME).write_bytes(OVERLAY + b"#" * 9000 + b"\n")
        result = self.run_tool("--check", str(source))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TARGET, result.stderr)


if __name__ == "__main__":
    unittest.main()
