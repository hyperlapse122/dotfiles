#!/usr/bin/env python3
"""One-shot host-side tool for the Gem80 HostRGB `0x60` raw HID vendor command.

Wire protocol: see R6, R7, R8 in
docs/plans/2026-09-10-0915-feat-gem80-hostrgb-firmware-verification-plan.md.
"""

import argparse
import os
import re
import select
import sys
from pathlib import Path

HIDRAW_ROOT = Path("/sys/class/hidraw")
HOSTRGB_USAGE_PAGE = 0xFF60
HOSTRGB_USAGE = 0x61
# Usage page 0xFF60 is QMK's generic raw HID page, so any QMK board matches it.
# The VID/PID pins the scan to this keyboard.
HOSTRGB_VENDOR_ID = 0x19F5
HOSTRGB_PRODUCT_ID = 0x3275

# Mirrored in keymap/keymap.c (HOSTRGB_CMD, HOSTRGB_PROTOCOL,
# HOSTRGB_LEDS_PER_PACKET, enum hostrgb_sub). test_hostrgb_probe.py parses that
# file and fails if the two drift apart.
HOSTRGB_CMD = 0x60
HOSTRGB_SUB_PROBE = 0x00
HOSTRGB_SUB_MODE = 0x01
HOSTRGB_SUB_SET = 0x02
HOSTRGB_PROTOCOL_REV = 1

PAYLOAD_SIZE = 32
LEDS_PER_PACKET = 9
# The board's own config.h undefines the 88 derived from keyboard.json's
# rgb_matrix layout and redefines RGB_MATRIX_LED_COUNT as 89; index 88 sits
# in the WS2812 chain with no layout entry. The 12 side LEDs are a separate
# chain and are not counted here.
EXPECTED_LED_COUNT = 89
DEFAULT_TIMEOUT = 1.0

# These values already appear in the committed verification log; keep them.
EXIT_OK = 0
EXIT_NO_NODE = 2
EXIT_PERMISSION_DENIED = 3
EXIT_NO_RESPONSE = 4
EXIT_UNEXPECTED_LED_COUNT = 5
EXIT_MALFORMED_RESPONSE = 6
EXIT_UNEXPECTED_PROTOCOL = 7
EXIT_DEVICE_ERROR = 8


# --- HID report descriptor parsing (usage page / usage node selection) -----


def iter_report_descriptor_items(data: bytes):
    """Yield (item_type, tag, value) for each short item in a HID report descriptor.

    item_type: 0=Main, 1=Global, 2=Local. Long items (0xFE) are skipped whole.
    """
    i = 0
    n = len(data)
    while i < n:
        prefix = data[i]
        if prefix == 0xFE:
            if i + 1 >= n:
                break
            data_size = data[i + 1]
            i += 3 + data_size
            continue
        size_code = prefix & 0x03
        item_type = (prefix >> 2) & 0x03
        tag = (prefix >> 4) & 0x0F
        size = (0, 1, 2, 4)[size_code]
        i += 1
        if i + size > n:
            break
        value = int.from_bytes(data[i : i + size], "little")
        i += size
        yield item_type, tag, value


def find_usage_pairs(data: bytes) -> set[tuple[int, int]]:
    """Return every (usage_page, usage) pair a report descriptor declares."""
    pairs: set[tuple[int, int]] = set()
    current_usage_page: int | None = None
    for item_type, tag, value in iter_report_descriptor_items(data):
        if item_type == 1 and tag == 0x0:  # Global: Usage Page
            current_usage_page = value
        elif item_type == 2 and tag == 0x0:  # Local: Usage
            if current_usage_page is not None:
                pairs.add((current_usage_page, value))
    return pairs


def _natural_key(name: str):
    match = re.search(r"(\d+)$", name)
    return int(match.group(1)) if match else name


def read_node_ids(node_dir: Path) -> tuple[int, int] | None:
    """Return (vendor_id, product_id) from a hidraw node's HID_ID uevent line.

    The line reads `HID_ID=<bus>:<vendor>:<product>` with each field in
    zero-padded hex. Returns None when the file is missing or unparseable.
    """
    try:
        uevent = (node_dir / "device" / "uevent").read_text()
    except OSError:
        return None
    match = re.search(r"^HID_ID=[0-9A-Fa-f]+:([0-9A-Fa-f]+):([0-9A-Fa-f]+)$", uevent, re.M)
    if match is None:
        return None
    return int(match.group(1), 16), int(match.group(2), 16)


def find_matching_nodes(
    hidraw_root: Path = HIDRAW_ROOT,
    usage_page: int = HOSTRGB_USAGE_PAGE,
    usage: int = HOSTRGB_USAGE,
    vendor_id: int | None = HOSTRGB_VENDOR_ID,
    product_id: int | None = HOSTRGB_PRODUCT_ID,
) -> list[str]:
    """Return hidraw node names for this keyboard that declare (usage_page, usage).

    Enumeration order is not stable across reboots, so results are sorted
    numerically to give a deterministic "first" candidate.
    """
    if not hidraw_root.is_dir():
        return []
    candidates = []
    for entry in sorted(hidraw_root.iterdir(), key=lambda p: _natural_key(p.name)):
        descriptor_path = entry / "device" / "report_descriptor"
        try:
            data = descriptor_path.read_bytes()
        except OSError:
            continue
        if (usage_page, usage) not in find_usage_pairs(data):
            continue
        if vendor_id is not None or product_id is not None:
            ids = read_node_ids(entry)
            if ids is None:
                continue
            if vendor_id is not None and ids[0] != vendor_id:
                continue
            if product_id is not None and ids[1] != product_id:
                continue
        candidates.append(entry.name)
    return candidates


# --- wire protocol: packet construction -------------------------------------


def build_write_packet(payload: bytes) -> bytes:
    """Prepend the leading report-ID byte a hidraw write needs (R6-R8 wire format)."""
    if len(payload) != PAYLOAD_SIZE:
        raise ValueError(f"payload must be {PAYLOAD_SIZE} bytes, got {len(payload)}")
    return b"\x00" + payload


def build_probe_payload() -> bytes:
    payload = bytearray(PAYLOAD_SIZE)
    payload[0] = HOSTRGB_CMD
    payload[1] = HOSTRGB_SUB_PROBE
    return bytes(payload)


def build_mode_payload(enter: bool) -> bytes:
    payload = bytearray(PAYLOAD_SIZE)
    payload[0] = HOSTRGB_CMD
    payload[1] = HOSTRGB_SUB_MODE
    payload[2] = 1 if enter else 0
    return bytes(payload)


def build_set_payload(
    start: int,
    colors: list[tuple[int, int, int]],
    leds_per_packet: int = LEDS_PER_PACKET,
) -> bytes:
    count = len(colors)
    if count > leds_per_packet:
        raise ValueError(f"at most {leds_per_packet} LEDs per packet, got {count}")
    payload = bytearray(PAYLOAD_SIZE)
    payload[0] = HOSTRGB_CMD
    payload[1] = HOSTRGB_SUB_SET
    payload[2] = start & 0xFF
    payload[3] = count & 0xFF
    offset = 4
    for r, g, b in colors:
        payload[offset] = r & 0xFF
        payload[offset + 1] = g & 0xFF
        payload[offset + 2] = b & 0xFF
        offset += 3
    return bytes(payload)


def build_frame_payloads(
    r: int,
    g: int,
    b: int,
    total_leds: int = EXPECTED_LED_COUNT,
    leds_per_packet: int = LEDS_PER_PACKET,
) -> list[bytes]:
    """Split a single flat color across `total_leds` LEDs into `0x60 0x02` packets."""
    if leds_per_packet < 1:
        raise ValueError(f"leds per packet must be at least 1, got {leds_per_packet}")
    payloads = []
    start = 0
    while start < total_leds:
        count = min(leds_per_packet, total_leds - start)
        payloads.append(build_set_payload(start, [(r, g, b)] * count, leds_per_packet))
        start += count
    return payloads


# --- probe response ----------------------------------------------------------


class ProbeResult:
    def __init__(self, protocol_rev: int, led_count: int, leds_per_packet: int):
        self.protocol_rev = protocol_rev
        self.led_count = led_count
        self.leds_per_packet = leds_per_packet


def parse_probe_response(response: bytes) -> ProbeResult:
    """Read the rev/LED-count/per-packet fields the firmware writes at data[2:5] (R6)."""
    if len(response) < 5:
        raise ValueError(f"probe response too short: {len(response)} bytes")
    if response[0] != HOSTRGB_CMD or response[1] != HOSTRGB_SUB_PROBE:
        raise ValueError(
            f"probe response header is 0x{response[0]:02x} 0x{response[1]:02x}, "
            f"expected 0x{HOSTRGB_CMD:02x} 0x{HOSTRGB_SUB_PROBE:02x}"
        )
    return ProbeResult(
        protocol_rev=response[2],
        led_count=response[3],
        leds_per_packet=response[4],
    )


# --- transport ----------------------------------------------------------------


class HidRawTransport:
    """Wraps a binary file object opened on a hidraw node. Also accepts a fake
    file-like object (e.g. an os.pipe() fd pair) so tests run without hardware.
    """

    def __init__(self, file_obj):
        self._file = file_obj

    def write_payload(self, payload: bytes) -> None:
        self._file.write(build_write_packet(payload))
        self._file.flush()

    def read_response(self, timeout: float) -> bytes | None:
        fileno = self._file.fileno()
        readable, _, _ = select.select([fileno], [], [], timeout)
        if not readable:
            return None
        return os.read(fileno, PAYLOAD_SIZE)


def open_device(node_name: str):
    return open(f"/dev/{node_name}", "r+b", buffering=0)


# --- CLI ------------------------------------------------------------------


def _select_node(err, device: str | None = None) -> str | None:
    if device:
        return device.removeprefix("/dev/")
    candidates = find_matching_nodes()
    if not candidates:
        print(
            f"no raw HID endpoint found for {HOSTRGB_VENDOR_ID:04x}:"
            f"{HOSTRGB_PRODUCT_ID:04x} (usage page 0x{HOSTRGB_USAGE_PAGE:04x}, "
            f"usage 0x{HOSTRGB_USAGE:02x}). The keyboard may be off, disconnected, "
            "or in a mode that does not expose the raw endpoint (see R9).",
            file=err,
        )
        return None
    if len(candidates) > 1:
        others = ", ".join(candidates[1:])
        print(
            f"multiple raw HID endpoints matched usage page "
            f"0x{HOSTRGB_USAGE_PAGE:04x} / usage 0x{HOSTRGB_USAGE:02x}: "
            f"using {candidates[0]}, also found {others}",
            file=err,
        )
    return candidates[0]


def _open_transport(node_name: str, err) -> tuple[object | None, int | None]:
    try:
        device = open_device(node_name)
    except PermissionError as exc:
        print(
            f"found /dev/{node_name} but could not open it: {exc}. A "
            "Bluetooth-attached node has no USB ancestor for the uaccess udev "
            "rule to match, so this is a distinct outcome from 'not found' "
            "(see R9).",
            file=err,
        )
        return None, EXIT_PERMISSION_DENIED
    except OSError as exc:
        print(
            f"found /dev/{node_name} but opening it failed: {exc}. The node may "
            "be busy or may have disappeared since it was selected.",
            file=err,
        )
        return None, EXIT_DEVICE_ERROR
    return device, None


def _acquire_device(args, err) -> tuple[object | None, str | None, int | None]:
    """Select the raw HID node and open it.

    Returns (device, node_name, None) on success, or (None, None, exit_code)
    carrying the outcome-specific code. Both callers must stay in lockstep on
    the three distinct wireless outcomes R9 depends on, so the sequence lives
    here once. The node name comes back because callers name it in diagnostics.
    """
    node_name = _select_node(err, getattr(args, "device", None))
    if node_name is None:
        return None, None, EXIT_NO_NODE
    device, failure = _open_transport(node_name, err)
    if device is None:
        return None, None, failure
    return device, node_name, None


def _with_device(args, err, action) -> int:
    """Run `action(transport, node_name)` on the opened node, classifying I/O errors."""
    device, node_name, failure = _acquire_device(args, err)
    if device is None:
        return failure
    try:
        return action(HidRawTransport(device), node_name)
    except OSError as exc:
        print(f"I/O error on /dev/{node_name}: {exc}", file=err)
        return EXIT_DEVICE_ERROR
    finally:
        device.close()


def _probe_device(transport, node_name, args, err) -> tuple[ProbeResult | None, int]:
    transport.write_payload(build_probe_payload())
    response = transport.read_response(args.timeout)
    if response is None:
        print(
            f"opened /dev/{node_name} but received no response within "
            f"{args.timeout}s. The device may not be running hostrgb firmware.",
            file=err,
        )
        return None, EXIT_NO_RESPONSE
    try:
        return parse_probe_response(response), EXIT_OK
    except ValueError as exc:
        print(f"unusable probe response from /dev/{node_name}: {exc}", file=err)
        return None, EXIT_MALFORMED_RESPONSE


def _check_probe_result(result: ProbeResult, err) -> int:
    """Refuse to drive a device whose reported protocol this tool does not implement."""
    if result.led_count != EXPECTED_LED_COUNT:
        print(
            f"LED count {result.led_count} != expected {EXPECTED_LED_COUNT} -- "
            "stop: the keymap may be built against the wrong board.",
            file=err,
        )
        return EXIT_UNEXPECTED_LED_COUNT
    if result.protocol_rev != HOSTRGB_PROTOCOL_REV:
        print(
            f"protocol revision {result.protocol_rev} != expected "
            f"{HOSTRGB_PROTOCOL_REV} -- stop: this tool implements revision "
            f"{HOSTRGB_PROTOCOL_REV} only.",
            file=err,
        )
        return EXIT_UNEXPECTED_PROTOCOL
    if result.leds_per_packet < 1:
        print(
            f"device reports {result.leds_per_packet} LEDs per packet -- stop: "
            "no frame can be built from that.",
            file=err,
        )
        return EXIT_UNEXPECTED_PROTOCOL
    return EXIT_OK


def cmd_probe(args, out=None, err=None) -> int:
    out = sys.stdout if out is None else out
    err = sys.stderr if err is None else err

    def action(transport, node_name):
        result, failure = _probe_device(transport, node_name, args, err)
        if result is None:
            return failure
        print(f"node: /dev/{node_name}", file=out)
        print(f"protocol revision: {result.protocol_rev}", file=out)
        print(f"LED count: {result.led_count}", file=out)
        print(f"LEDs per packet: {result.leds_per_packet}", file=out)
        return _check_probe_result(result, err)

    return _with_device(args, err, action)


def _write_confirmed(transport, node_name, payloads: list[bytes], args, err) -> int:
    """Write each payload and wait for the firmware's echo of that packet.

    via_command_kb() replies on every handled branch, so a missing or mismatched
    echo means the device did not handle the command -- exit 0 would otherwise
    mean only that the write syscall returned.
    """
    for payload in payloads:
        transport.write_payload(payload)
        response = transport.read_response(args.timeout)
        if response is None:
            print(
                f"/dev/{node_name} did not acknowledge command "
                f"0x{payload[0]:02x} 0x{payload[1]:02x} within {args.timeout}s.",
                file=err,
            )
            return EXIT_NO_RESPONSE
        if len(response) < 2 or response[0] != payload[0] or response[1] != payload[1]:
            print(
                f"/dev/{node_name} answered command 0x{payload[0]:02x} "
                f"0x{payload[1]:02x} with an unexpected echo: {response[:2].hex(' ')}.",
                file=err,
            )
            return EXIT_MALFORMED_RESPONSE
    return EXIT_OK


def _write_only(payloads: list[bytes], args, err=None) -> int:
    err = sys.stderr if err is None else err

    def action(transport, node_name):
        return _write_confirmed(transport, node_name, payloads, args, err)

    return _with_device(args, err, action)


def cmd_enter(args) -> int:
    return _write_only([build_mode_payload(enter=True)], args)


def cmd_exit(args) -> int:
    return _write_only([build_mode_payload(enter=False)], args)


def cmd_set(args) -> int:
    payload = build_set_payload(args.index, [(args.r, args.g, args.b)])
    return _write_only([payload], args)


def cmd_frame(args, err=None) -> int:
    """Probe first, then build the frame from the values the device reported."""
    err = sys.stderr if err is None else err

    def action(transport, node_name):
        result, failure = _probe_device(transport, node_name, args, err)
        if result is None:
            return failure
        failure = _check_probe_result(result, err)
        if failure != EXIT_OK:
            return failure
        payloads = build_frame_payloads(
            args.r,
            args.g,
            args.b,
            total_leds=result.led_count,
            leds_per_packet=result.leds_per_packet,
        )
        return _write_confirmed(transport, node_name, payloads, args, err)

    return _with_device(args, err, action)


def _byte_value(text: str) -> int:
    value = int(text)
    if not 0 <= value <= 255:
        raise argparse.ArgumentTypeError(f"{text!r} is not in range 0-255")
    return value


def _led_index_value(text: str) -> int:
    """Bound the `set` index by the LED count, which the firmware silently clamps."""
    value = int(text)
    if not 0 <= value < EXPECTED_LED_COUNT:
        raise argparse.ArgumentTypeError(
            f"{text!r} is not in range 0-{EXPECTED_LED_COUNT - 1}"
        )
    return value


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help="seconds to wait for a device response (default: %(default)s)",
    )
    parser.add_argument(
        "--device",
        help="hidraw node to use (e.g. /dev/hidraw4), bypassing the VID/PID scan",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("probe", help="query protocol rev / LED count / per-packet")

    subparsers.add_parser("enter", help="enter host-direct mode (60 01 01)")

    subparsers.add_parser("exit", help="leave host-direct mode, restore EEPROM effect (60 01 00)")

    set_parser = subparsers.add_parser("set", help="set one LED's color (60 02)")
    set_parser.add_argument("index", type=_led_index_value)
    set_parser.add_argument("r", type=_byte_value)
    set_parser.add_argument("g", type=_byte_value)
    set_parser.add_argument("b", type=_byte_value)

    frame_parser = subparsers.add_parser(
        "frame", help=f"set all {EXPECTED_LED_COUNT} LEDs to one color (60 02 x10)"
    )
    frame_parser.add_argument("r", type=_byte_value)
    frame_parser.add_argument("g", type=_byte_value)
    frame_parser.add_argument("b", type=_byte_value)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    handlers = {
        "probe": cmd_probe,
        "enter": cmd_enter,
        "exit": cmd_exit,
        "set": cmd_set,
        "frame": cmd_frame,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
