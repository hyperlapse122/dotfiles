"""Tests for hostrgb-probe.py. Run with: python3 -m unittest discover.

No Python test convention exists elsewhere in this repo (checked before writing
this file), so these tests are placed beside the script they cover rather than
under a project-wide test directory.

Everything here runs without hardware: node selection is exercised against a
synthetic sysfs tree, and device I/O against os.pipe() file descriptors
standing in for a hidraw node.
"""

import importlib.util
import io
import os
import unittest
from pathlib import Path

_MODULE_PATH = Path(__file__).parent / "hostrgb-probe.py"
_spec = importlib.util.spec_from_file_location("hostrgb_probe", _MODULE_PATH)
hostrgb_probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hostrgb_probe)


def synthetic_descriptor(usage_page: int, usage: int) -> bytes:
    """A minimal HID report descriptor declaring one (usage_page, usage) pair."""
    return bytes(
        [
            0x06,
            usage_page & 0xFF,
            (usage_page >> 8) & 0xFF,  # Usage Page (global, 2 bytes)
            0x09,
            usage & 0xFF,  # Usage (local, 1 byte)
            0xA1,
            0x01,  # Collection (Application)
            0xC0,  # End Collection
        ]
    )


def write_fake_hidraw_tree(root: Path, nodes: dict[str, bytes]) -> None:
    for name, descriptor in nodes.items():
        device_dir = root / name / "device"
        device_dir.mkdir(parents=True)
        (device_dir / "report_descriptor").write_bytes(descriptor)


class FakeHidDevice:
    """Stands in for the open() result on a real /dev/hidrawN node.

    Reads come from one end of an os.pipe(); writes are just recorded, since
    HidRawTransport.read_response() always reads via os.read(fileno(), ...)
    rather than looping back what was written.
    """

    def __init__(self, incoming: bytes | None = None):
        self.written: list[bytes] = []
        self._read_fd, self._write_fd = os.pipe()
        self._closed = False
        if incoming is not None:
            os.write(self._write_fd, incoming)
            os.close(self._write_fd)
            self._write_fd = None

    def write(self, data: bytes) -> int:
        self.written.append(bytes(data))
        return len(data)

    def flush(self) -> None:
        pass

    def fileno(self) -> int:
        return self._read_fd

    def close(self) -> None:
        # The code under test (cmd_probe/_write_only) closes the device itself,
        # and tests also close it defensively in tearDown -- tolerate both.
        if self._closed:
            return
        self._closed = True
        os.close(self._read_fd)
        if self._write_fd is not None:
            os.close(self._write_fd)


def make_args(timeout: float = 0.05, **extra) -> "hostrgb_probe.argparse.Namespace":
    return hostrgb_probe.argparse.Namespace(timeout=timeout, **extra)


class ReportDescriptorParsingTests(unittest.TestCase):
    def test_finds_declared_usage_pair(self):
        data = synthetic_descriptor(0xFF60, 0x61)
        self.assertIn((0xFF60, 0x61), hostrgb_probe.find_usage_pairs(data))

    def test_does_not_report_unrelated_pair(self):
        data = synthetic_descriptor(0x0001, 0x0006)
        self.assertNotIn((0xFF60, 0x61), hostrgb_probe.find_usage_pairs(data))


class NodeSelectionTests(unittest.TestCase):
    def test_no_hidraw_directory_returns_empty(self, tmp_path=None):
        missing_root = Path("/nonexistent-for-test/hidraw-root")
        self.assertEqual(hostrgb_probe.find_matching_nodes(missing_root), [])

    def test_no_matching_node_found(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_hidraw_tree(
                root, {"hidraw0": synthetic_descriptor(0x0001, 0x0006)}
            )
            self.assertEqual(hostrgb_probe.find_matching_nodes(root), [])

    def test_single_matching_node_among_others(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_hidraw_tree(
                root,
                {
                    "hidraw0": synthetic_descriptor(0x0001, 0x0006),
                    "hidraw1": synthetic_descriptor(0xFF60, 0x61),
                    "hidraw2": synthetic_descriptor(0x000C, 0x0001),
                },
            )
            self.assertEqual(hostrgb_probe.find_matching_nodes(root), ["hidraw1"])

    def test_multiple_matches_sorted_numerically_first_is_lowest(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_hidraw_tree(
                root,
                {
                    "hidraw10": synthetic_descriptor(0xFF60, 0x61),
                    "hidraw2": synthetic_descriptor(0xFF60, 0x61),
                    "hidraw1": synthetic_descriptor(0xFF60, 0x61),
                },
            )
            candidates = hostrgb_probe.find_matching_nodes(root)
            self.assertEqual(candidates, ["hidraw1", "hidraw2", "hidraw10"])


class PacketFramingTests(unittest.TestCase):
    def test_write_packet_is_33_bytes_with_leading_report_id(self):
        payload = hostrgb_probe.build_probe_payload()
        packet = hostrgb_probe.build_write_packet(payload)
        self.assertEqual(len(packet), 33)
        self.assertEqual(packet[0], 0x00)

    def test_every_subcommand_payload_yields_a_33_byte_write(self):
        payloads = [
            hostrgb_probe.build_probe_payload(),
            hostrgb_probe.build_mode_payload(enter=True),
            hostrgb_probe.build_mode_payload(enter=False),
            hostrgb_probe.build_set_payload(0, [(255, 0, 0)]),
        ] + hostrgb_probe.build_frame_payloads(1, 2, 3)
        for payload in payloads:
            self.assertEqual(len(hostrgb_probe.build_write_packet(payload)), 33)

    def test_set_command_matches_protocol(self):
        # AE1: `set 0 255 0 0` -> `60 02 00 01 FF 00 00 ...`
        payload = hostrgb_probe.build_set_payload(0, [(255, 0, 0)])
        self.assertEqual(payload[:7], bytes([0x60, 0x02, 0x00, 0x01, 0xFF, 0x00, 0x00]))
        self.assertEqual(len(payload), 32)

    def test_exit_command_matches_protocol(self):
        # AE2: `exit` -> `60 01 00`
        payload = hostrgb_probe.build_mode_payload(enter=False)
        self.assertEqual(payload[:3], bytes([0x60, 0x01, 0x00]))

    def test_enter_command_matches_protocol(self):
        payload = hostrgb_probe.build_mode_payload(enter=True)
        self.assertEqual(payload[:3], bytes([0x60, 0x01, 0x01]))

    def test_set_payload_rejects_more_than_nine_leds(self):
        with self.assertRaises(ValueError):
            hostrgb_probe.build_set_payload(0, [(0, 0, 0)] * (hostrgb_probe.LEDS_PER_PACKET + 1))


class FrameArithmeticTests(unittest.TestCase):
    def test_frame_splits_into_exactly_ten_packets(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30)
        self.assertEqual(len(payloads), 10)

    def test_last_packet_count_is_eight(self):
        # 89 LEDs at 9 per packet: 9 packets of 9 (81) + 1 packet of 8.
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30)
        self.assertEqual(payloads[-1][3], 8)

    def test_first_nine_packets_carry_nine_leds(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30)
        for payload in payloads[:9]:
            self.assertEqual(payload[3], hostrgb_probe.LEDS_PER_PACKET)

    def test_packet_start_indices_are_contiguous(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30)
        starts = [payload[2] for payload in payloads]
        self.assertEqual(starts, [0, 9, 18, 27, 36, 45, 54, 63, 72, 81])

    def test_total_led_count_covered_is_89(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30)
        self.assertEqual(sum(payload[3] for payload in payloads), 89)


class ProbeResponseParsingTests(unittest.TestCase):
    def test_parses_rev_led_count_and_leds_per_packet(self):
        response = bytes([0x60, 0x00, 1, 89, 9]) + bytes(27)
        result = hostrgb_probe.parse_probe_response(response)
        self.assertEqual(result.protocol_rev, 1)
        self.assertEqual(result.led_count, 89)
        self.assertEqual(result.leds_per_packet, 9)

    def test_rejects_truncated_response(self):
        with self.assertRaises(ValueError):
            hostrgb_probe.parse_probe_response(bytes([0x60, 0x00]))


class ThreeWayOutcomeCliTests(unittest.TestCase):
    """AE3: node-not-found, permission-denied and no-response must be distinct."""

    def setUp(self):
        self._orig_find = hostrgb_probe.find_matching_nodes
        self._orig_open = hostrgb_probe.open_device
        self._devices_to_close: list[FakeHidDevice] = []

    def tearDown(self):
        hostrgb_probe.find_matching_nodes = self._orig_find
        hostrgb_probe.open_device = self._orig_open
        for device in self._devices_to_close:
            device.close()

    def test_no_node_found_exits_with_dedicated_code(self):
        hostrgb_probe.find_matching_nodes = lambda: []
        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_NO_NODE)
        self.assertIn("no raw HID endpoint found", err.getvalue())

    def test_permission_denied_exits_with_dedicated_code(self):
        hostrgb_probe.find_matching_nodes = lambda: ["hidraw1"]

        def raise_permission_error(node_name):
            raise PermissionError("Permission denied")

        hostrgb_probe.open_device = raise_permission_error
        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_PERMISSION_DENIED)
        self.assertIn("could not open it", err.getvalue())

    def test_no_response_exits_with_dedicated_code(self):
        hostrgb_probe.find_matching_nodes = lambda: ["hidraw1"]
        device = FakeHidDevice(incoming=None)
        self._devices_to_close.append(device)
        hostrgb_probe.open_device = lambda node_name: device

        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(timeout=0.05), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_NO_RESPONSE)
        self.assertIn("no response", err.getvalue())

    def test_all_three_outcomes_have_distinct_exit_codes(self):
        codes = {
            hostrgb_probe.EXIT_NO_NODE,
            hostrgb_probe.EXIT_PERMISSION_DENIED,
            hostrgb_probe.EXIT_NO_RESPONSE,
        }
        self.assertEqual(len(codes), 3)


class ProbeStopConditionTests(unittest.TestCase):
    def setUp(self):
        self._orig_find = hostrgb_probe.find_matching_nodes
        self._orig_open = hostrgb_probe.open_device

    def tearDown(self):
        hostrgb_probe.find_matching_nodes = self._orig_find
        hostrgb_probe.open_device = self._orig_open

    def _run_probe_with_response(self, response: bytes) -> tuple[int, str]:
        hostrgb_probe.find_matching_nodes = lambda: ["hidraw1"]
        device = FakeHidDevice(incoming=response)
        hostrgb_probe.open_device = lambda node_name: device
        out, err = io.StringIO(), io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), out=out, err=err)
        return code, err.getvalue()

    def test_89_leds_succeeds(self):
        response = bytes([0x60, 0x00, 1, 89, 9]) + bytes(27)
        code, _ = self._run_probe_with_response(response)
        self.assertEqual(code, hostrgb_probe.EXIT_OK)

    def test_wrong_led_count_fails_with_dedicated_code(self):
        response = bytes([0x60, 0x00, 1, 42, 9]) + bytes(27)
        code, err = self._run_probe_with_response(response)
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_LED_COUNT)
        self.assertIn("42", err)


class WriteOnlyCommandTests(unittest.TestCase):
    """enter/exit/set/frame only need to reach the device with the right bytes."""

    def setUp(self):
        self._orig_find = hostrgb_probe.find_matching_nodes
        self._orig_open = hostrgb_probe.open_device
        hostrgb_probe.find_matching_nodes = lambda: ["hidraw1"]
        self.device = FakeHidDevice(incoming=None)
        hostrgb_probe.open_device = lambda node_name: self.device

    def tearDown(self):
        hostrgb_probe.find_matching_nodes = self._orig_find
        hostrgb_probe.open_device = self._orig_open
        self.device.close()

    def test_set_writes_a_single_33_byte_packet(self):
        code = hostrgb_probe.cmd_set(make_args(index=0, r=255, g=0, b=0))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(len(self.device.written), 1)
        self.assertEqual(len(self.device.written[0]), 33)
        self.assertEqual(
            self.device.written[0][:8], bytes([0x00, 0x60, 0x02, 0x00, 0x01, 0xFF, 0x00, 0x00])
        )

    def test_frame_writes_ten_packets(self):
        code = hostrgb_probe.cmd_frame(make_args(r=1, g=2, b=3))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(len(self.device.written), 10)

    def test_frame_last_packet_carries_the_remainder(self):
        # 89 LEDs at 9 per packet is 9 full packets plus a remainder of 8.
        # An earlier draft of the plan said 4; assert the arithmetic so a
        # regression cannot silently drop three keys from a full frame.
        payloads = hostrgb_probe.build_frame_payloads(1, 2, 3)
        self.assertEqual(payloads[-1][2], 81)
        self.assertEqual(payloads[-1][3], 8)
        self.assertEqual(sum(p[3] for p in payloads), 89)


if __name__ == "__main__":
    unittest.main()
