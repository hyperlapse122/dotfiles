"""Tests for hostrgb-probe.py. Run with: python3 -m unittest discover.

No Python test convention exists elsewhere in this repo (checked before writing
this file), so these tests are placed beside the script they cover rather than
under a project-wide test directory.

Everything here runs without hardware: node selection is exercised against a
synthetic sysfs tree, and device I/O against os.pipe() file descriptors
standing in for a hidraw node.
"""

import contextlib
import importlib.util
import io
import os
import re
import signal
import unittest
from unittest import mock
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


def write_fake_hidraw_tree(
    root: Path,
    nodes: dict[str, bytes],
    ids: dict[str, tuple[int, int]] | None = None,
) -> None:
    """Build a synthetic /sys/class/hidraw tree.

    Each node gets the Gem80's VID/PID unless `ids` overrides it, because
    find_matching_nodes filters on the HID_ID uevent line as well as the
    usage page.
    """
    ids = ids or {}
    for name, descriptor in nodes.items():
        device_dir = root / name / "device"
        device_dir.mkdir(parents=True)
        (device_dir / "report_descriptor").write_bytes(descriptor)
        vendor_id, product_id = ids.get(
            name, (hostrgb_probe.HOSTRGB_VENDOR_ID, hostrgb_probe.HOSTRGB_PRODUCT_ID)
        )
        (device_dir / "uevent").write_text(
            "DRIVER=hid-generic\n"
            f"HID_ID=0003:{vendor_id:08X}:{product_id:08X}\n"
            "HID_NAME=fake\n"
        )


class FakeHidDevice:
    """Stands in for the open() result on a real /dev/hidrawN node.

    Reads come from one end of an os.pipe(); writes are recorded, and with
    `echo=True` the payload is also pushed back down the pipe, standing in for
    the firmware's raw_hid_send() reply on every handled branch.

    `echo_transform` rewrites the echoed payload so a test can stage a reply
    that does not match the request.
    """

    def __init__(self, incoming: bytes | None = None, echo: bool = False, echo_transform=None):
        self.written: list[bytes] = []
        self._read_fd, self._write_fd = os.pipe()
        self._closed = False
        self._echo = echo
        self._echo_transform = echo_transform
        if incoming is not None:
            os.write(self._write_fd, incoming)
            if not echo:
                os.close(self._write_fd)
                self._write_fd = None

    def write(self, data: bytes) -> int:
        self.written.append(bytes(data))
        if self._echo and self._write_fd is not None:
            payload = bytes(data)[1:]  # drop the leading report-ID byte
            if self._echo_transform is not None:
                payload = self._echo_transform(payload)
            if payload:
                os.write(self._write_fd, payload)
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


def make_args(
    timeout: float = 0.05, device: str | None = None, **extra
) -> "hostrgb_probe.argparse.Namespace":
    return hostrgb_probe.argparse.Namespace(timeout=timeout, device=device, **extra)


def probe_response(
    rev: int = 2,
    led_count: int = 101,
    leds_per_packet: int = 9,
    side_first: int = 89,
) -> bytes:
    return bytes([0x60, 0x00, rev, led_count, leds_per_packet, side_first]) + bytes(26)


def firmware_echo(
    rev: int = 2,
    led_count: int = 101,
    leds_per_packet: int = 9,
    side_first: int = 89,
):
    """Echo a payload the way via_command_kb() does: probe carries the report."""

    def transform(payload: bytes) -> bytes:
        if payload[1] != hostrgb_probe.HOSTRGB_SUB_PROBE:
            return payload
        data = bytearray(payload)
        data[2], data[3], data[4], data[5] = rev, led_count, leds_per_packet, side_first
        return bytes(data)

    return transform


class PatchedProbeTestCase(unittest.TestCase):
    """Patches the two module seams the CLI tests stub.

    mock.patch always restores, so a future test class cannot forget the
    tearDown half and leak a stub into a later test -- which is the failure
    the three hand-rolled save/restore pairs this replaces were exposed to.
    """

    def patch_nodes(self, nodes):
        patcher = mock.patch.object(hostrgb_probe, "find_matching_nodes", lambda: nodes)
        patcher.start()
        self.addCleanup(patcher.stop)

    def patch_device(self, device):
        self.patch_open_device(lambda node_name: device)
        self.addCleanup(device.close)

    def patch_open_device(self, replacement):
        patcher = mock.patch.object(hostrgb_probe, "open_device", replacement)
        patcher.start()
        self.addCleanup(patcher.stop)


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

    def test_another_qmk_board_on_the_same_usage_page_is_skipped(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_hidraw_tree(
                root,
                {
                    "hidraw0": synthetic_descriptor(0xFF60, 0x61),
                    "hidraw1": synthetic_descriptor(0xFF60, 0x61),
                },
                ids={"hidraw0": (0xFEED, 0x0000)},
            )
            self.assertEqual(hostrgb_probe.find_matching_nodes(root), ["hidraw1"])

    def test_node_without_hid_id_is_skipped(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_hidraw_tree(root, {"hidraw0": synthetic_descriptor(0xFF60, 0x61)})
            (root / "hidraw0" / "device" / "uevent").unlink()
            self.assertEqual(hostrgb_probe.find_matching_nodes(root), [])

    def test_hid_id_is_read_as_hex(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_fake_hidraw_tree(root, {"hidraw0": synthetic_descriptor(0xFF60, 0x61)})
            self.assertEqual(
                hostrgb_probe.read_node_ids(root / "hidraw0"),
                (hostrgb_probe.HOSTRGB_VENDOR_ID, hostrgb_probe.HOSTRGB_PRODUCT_ID),
            )


class PacketFramingTests(unittest.TestCase):
    def test_write_packet_is_33_bytes_with_leading_report_id(self):
        payload = hostrgb_probe.build_probe_payload()
        packet = hostrgb_probe.build_write_packet(payload)
        self.assertEqual(len(packet), 33)
        self.assertEqual(packet[0], 0x00)

    def test_every_subcommand_payload_yields_a_33_byte_write(self):
        payloads = [
            hostrgb_probe.build_probe_payload(),
            hostrgb_probe.build_mode_payload(mask=hostrgb_probe.REGION_KEYS, deadline_units=50),
            hostrgb_probe.build_mode_payload(mask=0),
            hostrgb_probe.build_set_payload(0, [(255, 0, 0)]),
            hostrgb_probe.build_heartbeat_payload(50),
        ] + hostrgb_probe.build_frame_payloads(1, 2, 3, total_leds=101)
        for payload in payloads:
            self.assertEqual(len(hostrgb_probe.build_write_packet(payload)), 33)

    def test_set_command_matches_protocol(self):
        # AE1: `set 0 255 0 0` -> `60 02 00 01 FF 00 00 ...`
        payload = hostrgb_probe.build_set_payload(0, [(255, 0, 0)])
        self.assertEqual(payload[:7], bytes([0x60, 0x02, 0x00, 0x01, 0xFF, 0x00, 0x00]))
        self.assertEqual(len(payload), 32)

    def test_exit_command_matches_protocol(self):
        # AE2: `exit` -> `60 01 00`
        payload = hostrgb_probe.build_mode_payload(mask=0)
        self.assertEqual(payload[:3], bytes([0x60, 0x01, 0x00]))

    def test_enter_command_matches_protocol(self):
        payload = hostrgb_probe.build_mode_payload(mask=hostrgb_probe.REGION_KEYS, deadline_units=50)
        self.assertEqual(payload[:5], bytes([0x60, 0x01, 0x01, 0x32, 0x00]))

    def test_heartbeat_command_matches_protocol(self):
        payload = hostrgb_probe.build_heartbeat_payload(50)
        self.assertEqual(payload[:4], bytes([0x60, 0x03, 0x32, 0x00]))

    def test_set_payload_rejects_more_than_nine_leds(self):
        with self.assertRaises(ValueError):
            hostrgb_probe.build_set_payload(0, [(0, 0, 0)] * (hostrgb_probe.LEDS_PER_PACKET + 1))


class FrameArithmeticTests(unittest.TestCase):
    def test_frame_splits_into_twelve_packets(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30, total_leds=101)
        self.assertEqual(len(payloads), 12)

    def test_last_packet_count_is_two(self):
        # 101 LEDs at 9 per packet: 11 packets of 9 (99) + 1 packet of 2.
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30, total_leds=101)
        self.assertEqual(payloads[-1][3], 2)

    def test_first_nine_packets_carry_nine_leds(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30, total_leds=101)
        for payload in payloads[:11]:
            self.assertEqual(payload[3], hostrgb_probe.LEDS_PER_PACKET)

    def test_packet_start_indices_are_contiguous(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30, total_leds=101)
        starts = [payload[2] for payload in payloads]
        self.assertEqual(starts, [0, 9, 18, 27, 36, 45, 54, 63, 72, 81, 90, 99])

    def test_total_led_count_covered_is_reported_count(self):
        payloads = hostrgb_probe.build_frame_payloads(10, 20, 30, total_leds=101)
        self.assertEqual(sum(payload[3] for payload in payloads), 101)


class ProbeResponseParsingTests(unittest.TestCase):
    def test_parses_rev_led_count_and_leds_per_packet(self):
        result = hostrgb_probe.parse_probe_response(probe_response())
        self.assertEqual(result.protocol_rev, 2)
        self.assertEqual(result.led_count, 101)
        self.assertEqual(result.leds_per_packet, 9)
        self.assertEqual(result.side_first, 89)

    def test_rejects_truncated_response(self):
        with self.assertRaises(ValueError):
            hostrgb_probe.parse_probe_response(bytes([0x60, 0x00]))

    def test_rejects_response_for_another_command(self):
        # A stale 0x60 0x01 mode echo left on the endpoint must not be read as
        # a protocol revision and LED count.
        response = bytes([0x60, 0x01, 1, 0, 0]) + bytes(27)
        with self.assertRaises(ValueError):
            hostrgb_probe.parse_probe_response(response)

    def test_rejects_response_from_a_foreign_report(self):
        response = bytes([0x01, 0x00, 1, 89, 9]) + bytes(27)
        with self.assertRaises(ValueError):
            hostrgb_probe.parse_probe_response(response)


class ThreeWayOutcomeCliTests(PatchedProbeTestCase):
    """AE3: node-not-found, permission-denied and no-response must be distinct."""


    def test_no_node_found_exits_with_dedicated_code(self):
        self.patch_nodes([])
        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_NO_NODE)
        self.assertIn("no raw HID endpoint found", err.getvalue())

    def test_permission_denied_exits_with_dedicated_code(self):
        self.patch_nodes(["hidraw1"])

        def raise_permission_error(node_name):
            raise PermissionError("Permission denied")

        self.patch_open_device(raise_permission_error)
        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_PERMISSION_DENIED)
        self.assertIn("could not open it", err.getvalue())

    def test_no_response_exits_with_dedicated_code(self):
        self.patch_nodes(["hidraw1"])
        device = FakeHidDevice(incoming=None)
        self.patch_device(device)

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


class StubRestorationTests(unittest.TestCase):
    """PatchedProbeTestCase's docstring promises no stub outlives its test."""

    def test_permission_denied_case_restores_open_device(self):
        original = hostrgb_probe.open_device
        suite = unittest.TestLoader().loadTestsFromName(
            "test_permission_denied_exits_with_dedicated_code", ThreeWayOutcomeCliTests
        )
        result = unittest.TestResult()
        suite.run(result)
        self.assertTrue(result.wasSuccessful())
        self.assertIs(hostrgb_probe.open_device, original)


class ProbeStopConditionTests(PatchedProbeTestCase):
    def _run_probe_with_response(self, response: bytes, nodes=None) -> tuple[int, str, str]:
        self.patch_nodes(nodes or ["hidraw1"])
        device = FakeHidDevice(incoming=response)
        self.patch_device(device)
        out, err = io.StringIO(), io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def test_reported_led_count_succeeds(self):
        code, out, _ = self._run_probe_with_response(probe_response())
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertIn("side LED first index: 89", out)

    def test_nonstandard_led_count_is_not_rejected_as_a_host_constant(self):
        code, _, _ = self._run_probe_with_response(probe_response(led_count=42, side_first=20))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)

    def test_invalid_region_boundary_fails_with_dedicated_code(self):
        code, _, err = self._run_probe_with_response(probe_response(side_first=102))
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_LED_COUNT)
        self.assertIn("side", err)

    def test_unimplemented_protocol_revision_fails_with_dedicated_code(self):
        code, _, err = self._run_probe_with_response(probe_response(rev=1))
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_PROTOCOL)
        self.assertIn("protocol revision 1", err)

    def test_truncated_response_reports_malformed_instead_of_crashing(self):
        code, _, err = self._run_probe_with_response(bytes([0x60, 0x00]))
        self.assertEqual(code, hostrgb_probe.EXIT_MALFORMED_RESPONSE)
        self.assertIn("too short", err)

    def test_wrong_header_reports_malformed(self):
        code, _, err = self._run_probe_with_response(
            bytes([0x60, 0x01, 1, 89, 9]) + bytes(27)
        )
        self.assertEqual(code, hostrgb_probe.EXIT_MALFORMED_RESPONSE)
        self.assertIn("header", err)

    def test_multiple_endpoints_are_reported_and_the_lowest_is_used(self):
        code, out, err = self._run_probe_with_response(
            probe_response(), nodes=["hidraw1", "hidraw2"]
        )
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertIn("multiple raw HID endpoints matched", err)
        self.assertIn("hidraw2", err)
        self.assertIn("node: /dev/hidraw1", out)


class DeviceErrorClassificationTests(PatchedProbeTestCase):
    def test_open_failure_other_than_permission_is_its_own_code(self):
        self.patch_nodes(["hidraw1"])

        def vanished(node_name):
            raise FileNotFoundError("No such device")

        self.patch_open_device(vanished)
        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), out=io.StringIO(), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_DEVICE_ERROR)
        self.assertIn("opening it failed", err.getvalue())

    def test_write_failure_is_reported_not_raised(self):
        self.patch_nodes(["hidraw1"])
        device = FakeHidDevice(incoming=None)

        def failing_write(data):
            raise OSError("device disconnected")

        device.write = failing_write
        self.patch_device(device)
        err = io.StringIO()
        code = hostrgb_probe.cmd_probe(make_args(), out=io.StringIO(), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_DEVICE_ERROR)
        self.assertIn("I/O error", err.getvalue())


class WriteCommandTests(PatchedProbeTestCase):
    """enter/exit/set/frame must confirm the firmware's echo, not just write."""

    def use_device(self, device):
        self.patch_nodes(["hidraw1"])
        self.device = device
        self.patch_device(device)
        return device

    def use_echoing_device(self, **echo_kwargs):
        return self.use_device(
            FakeHidDevice(echo=True, echo_transform=firmware_echo(**echo_kwargs))
        )

    def test_set_writes_a_single_33_byte_packet(self):
        self.use_echoing_device()
        code = hostrgb_probe.cmd_set(make_args(index=0, r=255, g=0, b=0))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(len(self.device.written), 2)
        self.assertEqual(len(self.device.written[1]), 33)
        self.assertEqual(
            self.device.written[1][:8],
            bytes([0x00, 0x60, 0x02, 0x00, 0x01, 0xFF, 0x00, 0x00]),
        )

    def test_enter_succeeds_when_acknowledged(self):
        self.use_echoing_device()
        self.assertEqual(
            hostrgb_probe.cmd_enter(make_args(values=["keys", "5000"])),
            hostrgb_probe.EXIT_OK,
        )
        self.assertEqual(self.device.written[1][1:6], bytes([0x60, 0x01, 0x01, 0xF4, 0x01]))

    def test_exit_succeeds_when_acknowledged(self):
        self.use_echoing_device()
        self.assertEqual(hostrgb_probe.cmd_exit(make_args()), hostrgb_probe.EXIT_OK)
        self.assertEqual(self.device.written[0][1:4], bytes([0x60, 0x01, 0x00]))

    def test_heartbeat_sends_deadline_in_ten_millisecond_units(self):
        self.use_echoing_device()
        code = hostrgb_probe.cmd_heartbeat(make_args(deadline_ms=500))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(self.device.written[0][1:5], bytes([0x60, 0x03, 0x32, 0x00]))

    def test_heartbeat_zero_is_rejected_without_a_write(self):
        self.use_echoing_device()
        err = io.StringIO()
        code = hostrgb_probe.cmd_heartbeat(make_args(deadline_ms=0), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_INVALID_ARGUMENT)
        self.assertEqual(self.device.written, [])
        self.assertIn("deadline", err.getvalue())

    def test_heartbeat_above_wire_limit_is_rejected_without_a_write(self):
        self.use_echoing_device()
        err = io.StringIO()
        code = hostrgb_probe.cmd_heartbeat(
            make_args(deadline_ms=hostrgb_probe.MAX_DEADLINE_MS + 1), err=err
        )
        self.assertEqual(code, hostrgb_probe.EXIT_INVALID_ARGUMENT)
        self.assertEqual(self.device.written, [])
        self.assertIn("655350", err.getvalue())

    def test_enter_side_sets_only_the_side_bit(self):
        self.use_echoing_device()
        code = hostrgb_probe.cmd_enter(make_args(values=["side", "5000"]))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(self.device.written[1][1:6], bytes([0x60, 0x01, 0x02, 0xF4, 0x01]))

    def test_enter_keys_and_side_sets_both_region_bits(self):
        self.use_echoing_device()
        code = hostrgb_probe.cmd_enter(make_args(values=["keys", "side", "5000"]))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(self.device.written[1][1:6], bytes([0x60, 0x01, 0x03, 0xF4, 0x01]))

    def test_enter_without_a_deadline_is_rejected_without_a_write(self):
        self.use_echoing_device()
        err = io.StringIO()
        code = hostrgb_probe.cmd_enter(make_args(values=["side"]), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_INVALID_ARGUMENT)
        self.assertEqual(self.device.written, [])
        self.assertIn("deadline", err.getvalue())

    def test_frame_writes_a_probe_then_twelve_packets(self):
        self.use_echoing_device()
        code = hostrgb_probe.cmd_frame(make_args(r=1, g=2, b=3))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(len(self.device.written), 13)
        self.assertEqual(self.device.written[0][1:3], bytes([0x60, 0x00]))
        self.assertEqual(sum(packet[4] for packet in self.device.written[1:]), 101)

    def test_silent_device_fails_instead_of_reporting_success(self):
        self.use_device(FakeHidDevice(incoming=None))
        err = io.StringIO()
        code = hostrgb_probe._write_only(
            [hostrgb_probe.build_mode_payload(mask=hostrgb_probe.REGION_KEYS, deadline_units=50)],
            make_args(),
            err=err,
        )
        self.assertEqual(code, hostrgb_probe.EXIT_NO_RESPONSE)
        self.assertIn("did not acknowledge", err.getvalue())

    def test_wrong_echo_fails_with_dedicated_code(self):
        def wrong_subcommand(payload):
            data = bytearray(payload)
            data[1] = 0x7F
            return bytes(data)

        self.use_device(FakeHidDevice(echo=True, echo_transform=wrong_subcommand))
        err = io.StringIO()
        code = hostrgb_probe._write_only(
            [hostrgb_probe.build_mode_payload(mask=0)], make_args(), err=err
        )
        self.assertEqual(code, hostrgb_probe.EXIT_MALFORMED_RESPONSE)
        self.assertIn("unexpected echo", err.getvalue())

    def test_frame_stops_when_a_later_packet_goes_unanswered(self):
        echo = firmware_echo()
        answered = {"count": 0}

        def drop_after_three(payload):
            answered["count"] += 1
            return echo(payload) if answered["count"] <= 3 else b""

        self.use_device(FakeHidDevice(echo=True, echo_transform=drop_after_three))
        err = io.StringIO()
        code = hostrgb_probe.cmd_frame(make_args(r=1, g=2, b=3), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_NO_RESPONSE)
        self.assertLess(len(self.device.written), 11)

    def test_frame_uses_the_packet_size_the_device_reported(self):
        self.use_echoing_device(leds_per_packet=8)
        code = hostrgb_probe.cmd_frame(make_args(r=1, g=2, b=3))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        packets = self.device.written[1:]
        self.assertEqual(len(packets), 13)  # 12 packets of 8 plus a remainder of 5
        self.assertTrue(all(packet[4] <= 8 for packet in packets))
        self.assertEqual(sum(packet[4] for packet in packets), 101)

    def test_frame_refuses_an_unimplemented_protocol_revision(self):
        self.use_echoing_device(rev=1)
        err = io.StringIO()
        code = hostrgb_probe.cmd_frame(make_args(r=1, g=2, b=3), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_PROTOCOL)
        self.assertEqual(len(self.device.written), 1)  # the probe only

    def test_frame_last_packet_carries_the_remainder(self):
        payloads = hostrgb_probe.build_frame_payloads(1, 2, 3, total_leds=101)
        self.assertEqual(payloads[-1][2], 99)
        self.assertEqual(payloads[-1][3], 2)
        self.assertEqual(sum(p[3] for p in payloads), 101)

    def test_set_probes_before_writing_a_side_index(self):
        self.use_echoing_device()
        code = hostrgb_probe.cmd_set(make_args(index=89, r=255, g=0, b=0))
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(self.device.written[1][1:8], bytes([0x60, 0x02, 0x59, 0x01, 0xFF, 0x00, 0x00]))

    def test_set_rejects_index_past_the_reported_count(self):
        self.use_echoing_device(led_count=90, side_first=89)
        err = io.StringIO()
        code = hostrgb_probe.cmd_set(make_args(index=90, r=255, g=0, b=0), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_LED_COUNT)
        self.assertEqual(len(self.device.written), 1)
        self.assertIn("90", err.getvalue())

    def test_set_payload_can_cross_the_reported_region_boundary(self):
        payload = hostrgb_probe.build_set_payload(88, [(1, 2, 3), (4, 5, 6), (7, 8, 9)])
        self.assertEqual(payload[:13], bytes([0x60, 0x02, 0x58, 0x03, 1, 2, 3, 4, 5, 6, 7, 8, 9]))

    def test_rejected_echo_is_reported_as_a_distinct_outcome(self):
        def rejected(payload):
            data = bytearray(payload)
            data[1] |= hostrgb_probe.HOSTRGB_SUB_REJECTED
            return bytes(data)

        self.use_device(FakeHidDevice(echo=True, echo_transform=rejected))
        err = io.StringIO()
        code = hostrgb_probe._write_only(
            [hostrgb_probe.build_heartbeat_payload(50)], make_args(), err=err
        )
        self.assertEqual(code, hostrgb_probe.EXIT_COMMAND_REJECTED)
        self.assertIn("rejected", err.getvalue())

    def test_hold_repeats_heartbeat_before_deadline_and_exits_on_signal(self):
        self.use_echoing_device()
        clock = [0.0]
        sleep_calls = []

        def fake_sleep(interval):
            sleep_calls.append(interval)
            clock[0] += interval
            # Stop once a heartbeat has actually gone out, so the assertion
            # below covers a full cycle rather than a fixed number of sleeps.
            if any(packet[2] == hostrgb_probe.HOSTRGB_SUB_HEARTBEAT for packet in self.device.written):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

        err = io.StringIO()
        with (
            mock.patch.object(hostrgb_probe.time, "sleep", side_effect=fake_sleep),
            mock.patch.object(hostrgb_probe.time, "monotonic", side_effect=lambda: clock[0]),
        ):
            code = hostrgb_probe.cmd_hold(make_args(values=["side", "5000"]), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        # The heartbeat lands inside the 5 s deadline, and direct mode is handed
        # back on the way out.
        self.assertEqual([packet[2] for packet in self.device.written], [0x00, 0x01, 0x03, 0x01])
        self.assertLess(clock[0], 5.0)

    def test_enter_refuses_a_device_still_on_revision_one(self):
        # AE10. This is the pre-flash check: the board still carries revision 1
        # when it runs, and after the flash the precondition is gone for good.
        self.use_echoing_device(rev=1, led_count=89, side_first=89)
        err = io.StringIO()
        code = hostrgb_probe.cmd_enter(make_args(values=["keys", "5000"]), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_PROTOCOL)
        # The probe went out and nothing followed it: no mode packet reached a
        # firmware that would not have understood it.
        self.assertEqual(len(self.device.written), 1)

    def test_frame_refuses_a_packet_width_the_payload_cannot_hold(self):
        # A device reporting 10 LEDs per packet would overrun the 32-byte
        # payload. That has to read as a protocol failure, not a traceback.
        self.use_echoing_device(leds_per_packet=10)
        err = io.StringIO()
        code = hostrgb_probe.cmd_frame(make_args(r=0, g=0, b=255), err=err)
        self.assertEqual(code, hostrgb_probe.EXIT_UNEXPECTED_PROTOCOL)
        # Only the probe went out; no frame packet followed.
        self.assertEqual(len(self.device.written), 1)

    def test_hold_re_enters_when_the_watchdog_reclaimed_the_region(self):
        # The firmware refuses a heartbeat sent outside direct mode. Without
        # acting on that, hold would keep writing frames nothing displays.
        rejected: list[bool] = []
        answer_probe = firmware_echo()

        def reject_heartbeats_once(payload):
            data = bytearray(answer_probe(payload))
            if data[1] == hostrgb_probe.HOSTRGB_SUB_HEARTBEAT and not rejected:
                rejected.append(True)
                data[1] |= hostrgb_probe.HOSTRGB_SUB_REJECTED
            return bytes(data)

        self.use_device(FakeHidDevice(echo=True, echo_transform=reject_heartbeats_once))
        clock = [0.0]

        def fake_sleep(interval):
            clock[0] += interval
            if len(self.device.written) >= 5:
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

        err = io.StringIO()
        with (
            mock.patch.object(hostrgb_probe.time, "sleep", side_effect=fake_sleep),
            mock.patch.object(hostrgb_probe.time, "monotonic", side_effect=lambda: clock[0]),
        ):
            code = hostrgb_probe.cmd_hold(make_args(values=["side", "5000"]), err=err)

        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        # probe, enter, refused heartbeat, re-enter, ... , exit
        sent = [packet[2] for packet in self.device.written]
        self.assertEqual(sent[:4], [0x00, 0x01, 0x03, 0x01])
        self.assertEqual(sent[-1], 0x01)
        self.assertIn("re-entering", err.getvalue())

    def test_hold_never_sleeps_past_the_stop_poll_interval(self):
        # A signal does not cut time.sleep() short (PEP 475), so a single long
        # sleep would leave an operator's Ctrl-C hanging for the whole interval.
        self.use_echoing_device()
        clock = [0.0]
        sleep_calls = []

        def fake_sleep(interval):
            sleep_calls.append(interval)
            clock[0] += interval
            if any(packet[2] == hostrgb_probe.HOSTRGB_SUB_HEARTBEAT for packet in self.device.written):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

        with (
            mock.patch.object(hostrgb_probe.time, "sleep", side_effect=fake_sleep),
            mock.patch.object(hostrgb_probe.time, "monotonic", side_effect=lambda: clock[0]),
        ):
            hostrgb_probe.cmd_hold(make_args(values=["side", "60000"]), err=io.StringIO())

        self.assertTrue(sleep_calls)
        self.assertLessEqual(max(sleep_calls), hostrgb_probe.HOLD_POLL_SECONDS)


class ArgumentParsingTests(unittest.TestCase):
    def test_led_index_is_not_bounded_by_a_host_led_count_constant(self):
        parser = hostrgb_probe.build_arg_parser()
        args = parser.parse_args(["set", "255", "255", "0", "0"])
        self.assertEqual(args.index, 255)

    def test_negative_led_index_is_rejected(self):
        parser = hostrgb_probe.build_arg_parser()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(["set", "-1", "255", "0", "0"])

    def test_color_channel_rejects_values_above_255(self):
        with self.assertRaises(hostrgb_probe.argparse.ArgumentTypeError):
            hostrgb_probe._byte_value("300")

    def test_frame_positional_order_is_r_g_b(self):
        args = hostrgb_probe.build_arg_parser().parse_args(["frame", "1", "2", "3"])
        self.assertEqual((args.command, args.r, args.g, args.b), ("frame", 1, 2, 3))

    def test_enter_accepts_regions_before_deadline(self):
        args = hostrgb_probe.build_arg_parser().parse_args(["enter", "keys", "side", "5000"])
        self.assertEqual(args.values, ["keys", "side", "5000"])

    def test_heartbeat_requires_a_deadline_argument(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            hostrgb_probe.build_arg_parser().parse_args(["heartbeat"])


class MainEntryPointTests(PatchedProbeTestCase):
    def test_main_dispatches_set_through_the_parser(self):
        self.patch_nodes(["hidraw1"])
        device = FakeHidDevice(echo=True, echo_transform=firmware_echo())
        self.patch_device(device)
        code = hostrgb_probe.main(["set", "0", "255", "0", "0"])
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(
            device.written[1][:5], bytes([0x00, 0x60, 0x02, 0x00, 0x01])
        )

    def test_main_dispatches_probe_and_honors_an_explicit_device(self):
        opened = []

        def open_named(node_name):
            opened.append(node_name)
            return FakeHidDevice(incoming=probe_response())

        self.patch_nodes([])  # the scan finds nothing; --device must still work
        self.patch_open_device(open_named)
        with contextlib.redirect_stdout(io.StringIO()):
            code = hostrgb_probe.main(["--device", "/dev/hidraw9", "probe"])
        self.assertEqual(code, hostrgb_probe.EXIT_OK)
        self.assertEqual(opened, ["hidraw9"])

    def test_every_subcommand_name_resolves_to_a_handler(self):
        for command, argv in (
            ("probe", ["probe"]),
            ("enter", ["enter", "5000"]),
            ("exit", ["exit"]),
            ("heartbeat", ["heartbeat", "500"]),
            ("hold", ["hold", "5000"]),
        ):
            args = hostrgb_probe.build_arg_parser().parse_args(argv)
            self.assertEqual(args.command, command)


class ConstantSyncTests(unittest.TestCase):
    """The C and Python sides of the 0x60 protocol must agree.

    keymap.c is compiled into the flashed binary, so this test only reads it.
    The LED count already drifted once (88 in one file, 89 in the other).
    """

    KEYMAP = Path(__file__).parent / "keymap" / "keymap.c"

    def keymap_source(self) -> str:
        return self.KEYMAP.read_text()

    def define_value(self, name: str) -> int:
        match = re.search(rf"^#define\s+{name}\s+(\S+)", self.keymap_source(), re.M)
        self.assertIsNotNone(match, f"{name} not found in {self.KEYMAP}")
        return int(match.group(1), 0)

    def enum_value(self, name: str) -> int:
        match = re.search(rf"^\s*{name}\s*=\s*([^,]+?),", self.keymap_source(), re.M)
        self.assertIsNotNone(match, f"{name} not found in {self.KEYMAP}")
        return self.c_integer(match.group(1))

    def c_integer(self, text: str) -> int:
        """Reads the literal forms this keymap uses: plain, hex, and `1 << n`."""
        text = text.strip()
        shift = re.fullmatch(r"(\S+)\s*<<\s*(\S+)", text)
        if shift:
            return int(shift.group(1), 0) << int(shift.group(2), 0)
        return int(text, 0)

    def test_command_byte_matches(self):
        self.assertEqual(self.define_value("HOSTRGB_CMD"), hostrgb_probe.HOSTRGB_CMD)

    def test_deadline_unit_matches(self):
        # A drift here silently rescales every deadline the host sends.
        self.assertEqual(
            self.define_value("HOSTRGB_DEADLINE_UNIT_MS"),
            hostrgb_probe.HOSTRGB_DEADLINE_UNIT_MS,
        )

    def test_rejection_bit_matches(self):
        self.assertEqual(
            self.define_value("HOSTRGB_SUB_REJECTED"),
            hostrgb_probe.HOSTRGB_SUB_REJECTED,
        )

    def test_region_bits_match(self):
        self.assertEqual(
            self.enum_value("HOSTRGB_REGION_KEYS"), hostrgb_probe.REGION_KEYS
        )
        self.assertEqual(
            self.enum_value("HOSTRGB_REGION_SIDE"), hostrgb_probe.REGION_SIDE
        )

    def test_side_region_lengths_match(self):
        self.assertEqual(
            self.define_value("HOSTRGB_SIDE_STRIP_COUNT"), hostrgb_probe.SIDE_STRIP_COUNT
        )
        self.assertEqual(
            self.define_value("HOSTRGB_SIDE_LOGO_COUNT"), hostrgb_probe.SIDE_LOGO_COUNT
        )

    def test_protocol_revision_matches(self):
        self.assertEqual(
            self.define_value("HOSTRGB_PROTOCOL"), hostrgb_probe.HOSTRGB_PROTOCOL_REV
        )

    def test_leds_per_packet_matches(self):
        self.assertEqual(
            self.define_value("HOSTRGB_LEDS_PER_PACKET"), hostrgb_probe.LEDS_PER_PACKET
        )

    def test_subcommand_values_match(self):
        self.assertEqual(self.enum_value("HOSTRGB_SUB_PROBE"), hostrgb_probe.HOSTRGB_SUB_PROBE)
        self.assertEqual(self.enum_value("HOSTRGB_SUB_MODE"), hostrgb_probe.HOSTRGB_SUB_MODE)
        self.assertEqual(self.enum_value("HOSTRGB_SUB_SET"), hostrgb_probe.HOSTRGB_SUB_SET)
        self.assertEqual(
            self.enum_value("HOSTRGB_SUB_HEARTBEAT"), hostrgb_probe.HOSTRGB_SUB_HEARTBEAT
        )

    def test_rejection_bit_matches(self):
        self.assertEqual(
            self.define_value("HOSTRGB_SUB_REJECTED"), hostrgb_probe.HOSTRGB_SUB_REJECTED
        )

    def test_side_region_counts_match(self):
        self.assertEqual(
            self.define_value("HOSTRGB_SIDE_STRIP_COUNT"), hostrgb_probe.SIDE_STRIP_COUNT
        )
        self.assertEqual(
            self.define_value("HOSTRGB_SIDE_LOGO_COUNT"), hostrgb_probe.SIDE_LOGO_COUNT
        )

    def test_side_boundary_uses_the_key_matrix_count(self):
        match = re.search(
            r"^#define\s+HOSTRGB_SIDE_FIRST\s+(\S+)", self.keymap_source(), re.M
        )
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "RGB_MATRIX_LED_COUNT")
        self.assertIsNotNone(
            re.search(
                r"^#define\s+HOSTRGB_LED_COUNT\s+\(RGB_MATRIX_LED_COUNT \+ HOSTRGB_SIDE_LED_COUNT\)",
                self.keymap_source(),
                re.M,
            )
        )
        self.assertEqual(hostrgb_probe.SIDE_LED_COUNT, 12)


if __name__ == "__main__":
    unittest.main()
