//! Protocol constants, packet builders, and response decoders for Gem80 0x60 commands.

// --- Wire protocol constants mirroring firmware/nuphy-gem80-hostrgb/keymap/keymap.c ---

/// Raw HID command byte handled by Gem80 HostRGB firmware.
pub const HOSTRGB_CMD: u8 = 0x60;

/// Expected protocol revision.
pub const HOSTRGB_PROTOCOL: u8 = 0x02;

/// Number of LEDs packed into a single 0x60 0x02 SET packet.
pub const HOSTRGB_LEDS_PER_PACKET: usize = 9;

/// Total number of LEDs on the Gem80 (89 keys matrix + 12 side strip/logo).
pub const HOSTRGB_LED_COUNT: usize = 101;

/// Index of the first side chain LED (also the count of key matrix LEDs).
pub const HOSTRGB_SIDE_FIRST: usize = 89;

/// Number of LEDs in the side top strip.
pub const HOSTRGB_SIDE_STRIP_COUNT: usize = 5;

/// Number of LEDs in the side logo.
pub const HOSTRGB_SIDE_LOGO_COUNT: usize = 7;

/// Total number of side LEDs (strip + logo).
pub const HOSTRGB_SIDE_LED_COUNT: usize = HOSTRGB_SIDE_STRIP_COUNT + HOSTRGB_SIDE_LOGO_COUNT; // 12

/// Deadline unit resolution in milliseconds (10 ms per unit).
pub const HOSTRGB_DEADLINE_UNIT_MS: u32 = 10;

/// Rejection bit flagged on the subcommand byte in responses.
pub const HOSTRGB_SUB_REJECTED: u8 = 0x80;

/// Standard Raw HID report payload size in bytes.
pub const PAYLOAD_SIZE: usize = 32;

// --- Subcommands ---
pub const HOSTRGB_SUB_PROBE: u8 = 0x00;
pub const HOSTRGB_SUB_MODE: u8 = 0x01;
pub const HOSTRGB_SUB_SET: u8 = 0x02;
pub const HOSTRGB_SUB_HEARTBEAT: u8 = 0x03;

// --- Region bits ---
pub const HOSTRGB_REGION_KEYS: u8 = 1 << 0; // 0x01
pub const HOSTRGB_REGION_SIDE: u8 = 1 << 1; // 0x02
pub const HOSTRGB_REGION_ALL: u8 = HOSTRGB_REGION_KEYS | HOSTRGB_REGION_SIDE; // 0x03

// --- USB / HID identification ---
pub const HOSTRGB_VENDOR_ID: u16 = 0x19F5;
pub const HOSTRGB_PRODUCT_ID: u16 = 0x3275;
pub const HOSTRGB_USAGE_PAGE: u16 = 0xFF60;
pub const HOSTRGB_USAGE: u16 = 0x61;

/// Maximum deadline in units (u16::MAX).
pub const MAX_DEADLINE_UNITS: u16 = 0xFFFF;
/// Maximum deadline in milliseconds.
pub const MAX_DEADLINE_MS: u32 = (MAX_DEADLINE_UNITS as u32) * HOSTRGB_DEADLINE_UNIT_MS;

/// Total number of packets required to send a full 101-LED frame.
/// 11 packets of 9 LEDs (99 LEDs) + 1 packet of 2 LEDs = 12 packets.
pub const PACKETS_PER_FULL_FRAME: usize =
    (HOSTRGB_LED_COUNT + HOSTRGB_LEDS_PER_PACKET - 1) / HOSTRGB_LEDS_PER_PACKET;

/// Error type for Gem80 device protocol and transport operations.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DeviceError {
    #[error("command 0x{subcommand:02X} rejected by device")]
    CommandRejected { subcommand: u8 },

    #[error("unexpected command byte: expected 0x{expected:02X}, got 0x{actual:02X}")]
    UnexpectedCommand { expected: u8, actual: u8 },

    #[error("unexpected subcommand byte: expected 0x{expected:02X}, got 0x{actual:02X}")]
    UnexpectedSubcommand { expected: u8, actual: u8 },

    #[error("incompatible firmware protocol: expected revision {expected}, got {actual}")]
    IncompatibleProtocol { expected: u8, actual: u8 },

    #[error("invalid LED count: {count} exceeds maximum {max}")]
    InvalidLedCount { count: usize, max: usize },

    #[error("invalid LED index: {start} + {count} exceeds maximum {max}")]
    LedRangeOutOfBounds {
        start: usize,
        count: usize,
        max: usize,
    },

    #[error("invalid deadline: {deadline_ms} ms (must be 1..{max} ms)")]
    InvalidDeadline { deadline_ms: u32, max: u32 },

    #[error("invalid region mask: 0x{mask:02X} contains unknown bits")]
    InvalidRegionMask { mask: u8 },

    #[error("read timed out after {timeout_ms} ms")]
    Timeout { timeout_ms: u32 },

    #[error("I/O error: {0}")]
    Io(String),

    #[error("device not found")]
    DeviceNotFound,
}

/// Decoded probe response from Gem80 firmware.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeResponse {
    pub protocol: u8,
    pub led_count: u8,
    pub leds_per_packet: u8,
    pub side_first: u8,
}

impl ProbeResponse {
    /// Check whether the reported protocol revision is compatible (revision 2).
    pub fn is_compatible(&self) -> bool {
        self.protocol == HOSTRGB_PROTOCOL
    }
}

/// Build a 32-byte PROBE command packet.
pub fn build_probe_packet() -> [u8; PAYLOAD_SIZE] {
    let mut packet = [0u8; PAYLOAD_SIZE];
    packet[0] = HOSTRGB_CMD;
    packet[1] = HOSTRGB_SUB_PROBE;
    packet
}

/// Parse and validate a 32-byte PROBE response packet.
pub fn parse_probe_response(data: &[u8; PAYLOAD_SIZE]) -> Result<ProbeResponse, DeviceError> {
    validate_response_header(data, HOSTRGB_SUB_PROBE)?;

    let protocol = data[2];
    let led_count = data[3];
    let leds_per_packet = data[4];
    let side_first = data[5];

    if protocol != HOSTRGB_PROTOCOL {
        return Err(DeviceError::IncompatibleProtocol {
            expected: HOSTRGB_PROTOCOL,
            actual: protocol,
        });
    }

    Ok(ProbeResponse {
        protocol,
        led_count,
        leds_per_packet,
        side_first,
    })
}

/// Convert milliseconds to 10 ms deadline units, rounded up or checked for validity.
pub fn deadline_ms_to_units(deadline_ms: u32) -> Result<u16, DeviceError> {
    if deadline_ms == 0 || deadline_ms > MAX_DEADLINE_MS {
        return Err(DeviceError::InvalidDeadline {
            deadline_ms,
            max: MAX_DEADLINE_MS,
        });
    }
    // Round up to ensure the watchdog deadline is not shorter than requested
    let units = (deadline_ms + HOSTRGB_DEADLINE_UNIT_MS - 1) / HOSTRGB_DEADLINE_UNIT_MS;
    if units > MAX_DEADLINE_UNITS as u32 {
        return Err(DeviceError::InvalidDeadline {
            deadline_ms,
            max: MAX_DEADLINE_MS,
        });
    }
    Ok(units as u16)
}

/// Build a 32-byte MODE command packet.
/// If `mask == 0` (exit direct mode), `deadline_ms` must be 0 and is ignored.
/// If `mask != 0`, `deadline_ms` must be > 0.
pub fn build_mode_packet(mask: u8, deadline_ms: u32) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
    if mask & !HOSTRGB_REGION_ALL != 0 {
        return Err(DeviceError::InvalidRegionMask { mask });
    }

    let deadline_units = if mask == 0 {
        0u16
    } else {
        deadline_ms_to_units(deadline_ms)?
    };

    let mut packet = [0u8; PAYLOAD_SIZE];
    packet[0] = HOSTRGB_CMD;
    packet[1] = HOSTRGB_SUB_MODE;
    packet[2] = mask;
    packet[3] = (deadline_units & 0xFF) as u8;
    packet[4] = ((deadline_units >> 8) & 0xFF) as u8;
    Ok(packet)
}

/// Parse and validate a 32-byte MODE response packet.
pub fn parse_mode_response(data: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
    validate_response_header(data, HOSTRGB_SUB_MODE)
}

/// Build a 32-byte SET command packet for up to 9 LEDs starting at index `start`.
pub fn build_set_packet(
    start: u8,
    colors: &[(u8, u8, u8)],
) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
    let count = colors.len();
    if count == 0 || count > HOSTRGB_LEDS_PER_PACKET {
        return Err(DeviceError::InvalidLedCount {
            count,
            max: HOSTRGB_LEDS_PER_PACKET,
        });
    }
    if (start as usize) + count > HOSTRGB_LED_COUNT {
        return Err(DeviceError::LedRangeOutOfBounds {
            start: start as usize,
            count,
            max: HOSTRGB_LED_COUNT,
        });
    }

    let mut packet = [0u8; PAYLOAD_SIZE];
    packet[0] = HOSTRGB_CMD;
    packet[1] = HOSTRGB_SUB_SET;
    packet[2] = start;
    packet[3] = count as u8;

    for (i, &(r, g, b)) in colors.iter().enumerate() {
        packet[4 + i * 3] = r;
        packet[5 + i * 3] = g;
        packet[6 + i * 3] = b;
    }

    Ok(packet)
}

/// Parse and validate a 32-byte SET response packet.
pub fn parse_set_response(data: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
    validate_response_header(data, HOSTRGB_SUB_SET)
}

/// Split a full 101-LED frame into exactly 12 `[u8; 32]` packets.
/// Packets 0..10 contain 9 LEDs each (total 99 LEDs).
/// Packet 11 contains the remaining 2 LEDs (LEDs 99 and 100).
pub fn build_frame_packets(colors: &[(u8, u8, u8); HOSTRGB_LED_COUNT]) -> Vec<[u8; PAYLOAD_SIZE]> {
    let mut packets = Vec::with_capacity(PACKETS_PER_FULL_FRAME);
    let mut offset = 0;
    while offset < HOSTRGB_LED_COUNT {
        let chunk_size = std::cmp::min(HOSTRGB_LEDS_PER_PACKET, HOSTRGB_LED_COUNT - offset);
        let slice = &colors[offset..offset + chunk_size];
        let packet =
            build_set_packet(offset as u8, slice).expect("frame chunk parameters must be valid");
        packets.push(packet);
        offset += chunk_size;
    }
    debug_assert_eq!(packets.len(), PACKETS_PER_FULL_FRAME);
    packets
}

/// Build a 32-byte HEARTBEAT command packet.
pub fn build_heartbeat_packet(deadline_ms: u32) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
    let deadline_units = deadline_ms_to_units(deadline_ms)?;
    let mut packet = [0u8; PAYLOAD_SIZE];
    packet[0] = HOSTRGB_CMD;
    packet[1] = HOSTRGB_SUB_HEARTBEAT;
    packet[2] = (deadline_units & 0xFF) as u8;
    packet[3] = ((deadline_units >> 8) & 0xFF) as u8;
    Ok(packet)
}

/// Parse and validate a 32-byte HEARTBEAT response packet.
pub fn parse_heartbeat_response(data: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
    validate_response_header(data, HOSTRGB_SUB_HEARTBEAT)
}

/// Helper to validate the response header:
/// 1. Verifies command byte is 0x60.
/// 2. Checks if rejection bit (0x80) is set on subcommand.
/// 3. Checks if subcommand matches expected subcommand.
fn validate_response_header(
    data: &[u8; PAYLOAD_SIZE],
    expected_sub: u8,
) -> Result<(), DeviceError> {
    if data[0] != HOSTRGB_CMD {
        return Err(DeviceError::UnexpectedCommand {
            expected: HOSTRGB_CMD,
            actual: data[0],
        });
    }

    let sub = data[1];
    if (sub & HOSTRGB_SUB_REJECTED) != 0 {
        return Err(DeviceError::CommandRejected {
            subcommand: sub & !HOSTRGB_SUB_REJECTED,
        });
    }

    if sub != expected_sub {
        return Err(DeviceError::UnexpectedSubcommand {
            expected: expected_sub,
            actual: sub,
        });
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_probe_request_layout() {
        let packet = build_probe_packet();
        assert_eq!(packet[0], HOSTRGB_CMD);
        assert_eq!(packet[1], HOSTRGB_SUB_PROBE);
        assert_eq!(&packet[2..], &[0u8; 30]);
    }

    #[test]
    fn test_probe_response_decoding() {
        let mut resp = [0u8; PAYLOAD_SIZE];
        resp[0] = HOSTRGB_CMD;
        resp[1] = HOSTRGB_SUB_PROBE;
        resp[2] = 2; // protocol rev 2
        resp[3] = 101; // led_count
        resp[4] = 9; // leds_per_packet
        resp[5] = 89; // side_first

        let probe = parse_probe_response(&resp).expect("valid probe response should decode");
        assert_eq!(probe.protocol, 2);
        assert_eq!(probe.led_count, 101);
        assert_eq!(probe.leds_per_packet, 9);
        assert_eq!(probe.side_first, 89);
        assert!(probe.is_compatible());
    }

    #[test]
    fn test_probe_response_incompatible_revision() {
        let mut resp = [0u8; PAYLOAD_SIZE];
        resp[0] = HOSTRGB_CMD;
        resp[1] = HOSTRGB_SUB_PROBE;
        resp[2] = 1; // protocol rev 1 (incompatible)
        resp[3] = 101;
        resp[4] = 9;
        resp[5] = 89;

        let err = parse_probe_response(&resp).unwrap_err();
        assert_eq!(
            err,
            DeviceError::IncompatibleProtocol {
                expected: 2,
                actual: 1,
            }
        );
    }

    #[test]
    fn test_mode_request_encoding() {
        // Direct mode with deadline 300 ms -> 30 units (0x001E)
        let packet =
            build_mode_packet(HOSTRGB_REGION_ALL, 300).expect("mode packet build should succeed");
        assert_eq!(packet[0], HOSTRGB_CMD);
        assert_eq!(packet[1], HOSTRGB_SUB_MODE);
        assert_eq!(packet[2], HOSTRGB_REGION_ALL);
        assert_eq!(packet[3], 30); // 300 / 10 = 30 low byte
        assert_eq!(packet[4], 0); // high byte
        assert_eq!(&packet[5..], &[0u8; 27]);

        // Exit mode (mask 0) -> deadline 0
        let exit_packet = build_mode_packet(0, 0).expect("exit mode packet build should succeed");
        assert_eq!(exit_packet[0], HOSTRGB_CMD);
        assert_eq!(exit_packet[1], HOSTRGB_SUB_MODE);
        assert_eq!(exit_packet[2], 0);
        assert_eq!(exit_packet[3], 0);
        assert_eq!(exit_packet[4], 0);

        // Invalid mask rejected
        let err = build_mode_packet(0x04, 300).unwrap_err();
        assert_eq!(err, DeviceError::InvalidRegionMask { mask: 0x04 });
    }

    #[test]
    fn test_rejection_bit_detected() {
        // Mode rejected
        let mut resp = [0u8; PAYLOAD_SIZE];
        resp[0] = HOSTRGB_CMD;
        resp[1] = HOSTRGB_SUB_MODE | HOSTRGB_SUB_REJECTED; // 0x81

        let err = parse_mode_response(&resp).unwrap_err();
        assert_eq!(
            err,
            DeviceError::CommandRejected {
                subcommand: HOSTRGB_SUB_MODE
            }
        );

        // Heartbeat rejected
        resp[1] = HOSTRGB_SUB_HEARTBEAT | HOSTRGB_SUB_REJECTED; // 0x83
        let err_hb = parse_heartbeat_response(&resp).unwrap_err();
        assert_eq!(
            err_hb,
            DeviceError::CommandRejected {
                subcommand: HOSTRGB_SUB_HEARTBEAT
            }
        );
    }

    #[test]
    fn test_mismatched_subcommand_in_queue_rejected() {
        // Suppose caller expected MODE (0x01), but response had leftover SET (0x02)
        let mut resp = [0u8; PAYLOAD_SIZE];
        resp[0] = HOSTRGB_CMD;
        resp[1] = HOSTRGB_SUB_SET;

        let err = parse_mode_response(&resp).unwrap_err();
        assert_eq!(
            err,
            DeviceError::UnexpectedSubcommand {
                expected: HOSTRGB_SUB_MODE,
                actual: HOSTRGB_SUB_SET,
            }
        );
    }

    #[test]
    fn test_full_frame_packet_chunking_12_packets() {
        let mut colors = [(0u8, 0u8, 0u8); HOSTRGB_LED_COUNT];
        for (i, c) in colors.iter_mut().enumerate() {
            *c = (i as u8, (i * 2) as u8, (i * 3) as u8);
        }

        let packets = build_frame_packets(&colors);
        assert_eq!(
            packets.len(),
            12,
            "101 LEDs must chunk into exactly 12 packets"
        );

        // Verify packets 0..11
        for i in 0..11 {
            assert_eq!(packets[i][0], HOSTRGB_CMD);
            assert_eq!(packets[i][1], HOSTRGB_SUB_SET);
            assert_eq!(packets[i][2], (i * 9) as u8); // start
            assert_eq!(packets[i][3], 9); // count
            for j in 0..9 {
                let led_idx = i * 9 + j;
                assert_eq!(packets[i][4 + j * 3], led_idx as u8);
                assert_eq!(packets[i][5 + j * 3], (led_idx * 2) as u8);
                assert_eq!(packets[i][6 + j * 3], (led_idx * 3) as u8);
            }
        }

        // Verify packet 11 (last packet: 2 LEDs, start=99, count=2)
        assert_eq!(packets[11][0], HOSTRGB_CMD);
        assert_eq!(packets[11][1], HOSTRGB_SUB_SET);
        assert_eq!(packets[11][2], 99); // start index 99
        assert_eq!(packets[11][3], 2); // count 2 LEDs (99, 100)
        assert_eq!(packets[11][4], 99);
        assert_eq!(packets[11][5], (99 * 2) as u8);
        assert_eq!(packets[11][6], (99 * 3) as u8);
        assert_eq!(packets[11][7], 100);
        assert_eq!(packets[11][8], (100 * 2) as u8);
        assert_eq!(packets[11][9], (100 * 3) as u8);
        // remaining bytes padded with 0
        assert_eq!(&packets[11][10..], &[0u8; 22]);
    }

    #[test]
    fn test_heartbeat_request_encoding() {
        // 150 ms -> 15 units
        let packet = build_heartbeat_packet(150).expect("heartbeat packet build should succeed");
        assert_eq!(packet[0], HOSTRGB_CMD);
        assert_eq!(packet[1], HOSTRGB_SUB_HEARTBEAT);
        assert_eq!(packet[2], 15); // low byte
        assert_eq!(packet[3], 0); // high byte
        assert_eq!(&packet[4..], &[0u8; 28]);

        // Zero deadline invalid
        let err = build_heartbeat_packet(0).unwrap_err();
        assert_eq!(
            err,
            DeviceError::InvalidDeadline {
                deadline_ms: 0,
                max: MAX_DEADLINE_MS
            }
        );
    }

    #[test]
    fn test_constants_match_firmware_keymap_c() {
        // Read keymap.c and assert that constants in protocol.rs match keymap.c exactly
        let keymap_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("firmware/nuphy-gem80-hostrgb/keymap/keymap.c");

        if !keymap_path.exists() {
            eprintln!(
                "Skipping keymap.c check: {} does not exist",
                keymap_path.display()
            );
            return;
        }

        let content = std::fs::read_to_string(&keymap_path).expect("should read keymap.c");

        let parse_define = |name: &str| -> u32 {
            let re = format!("#define {}", name);
            for line in content.lines() {
                if line.starts_with(&re) {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 3 {
                        let val_str = parts[2];
                        if let Ok(v) = val_str.parse::<u32>() {
                            return v;
                        }
                        if val_str.starts_with("0x") || val_str.starts_with("0X") {
                            if let Ok(v) = u32::from_str_radix(&val_str[2..], 16) {
                                return v;
                            }
                        }
                    }
                }
            }
            panic!("Could not find define {} in keymap.c", name);
        };

        assert_eq!(parse_define("HOSTRGB_CMD"), HOSTRGB_CMD as u32);
        assert_eq!(parse_define("HOSTRGB_PROTOCOL"), HOSTRGB_PROTOCOL as u32);
        assert_eq!(
            parse_define("HOSTRGB_LEDS_PER_PACKET"),
            HOSTRGB_LEDS_PER_PACKET as u32
        );
        assert_eq!(
            parse_define("HOSTRGB_SIDE_STRIP_COUNT"),
            HOSTRGB_SIDE_STRIP_COUNT as u32
        );
        assert_eq!(
            parse_define("HOSTRGB_SIDE_LOGO_COUNT"),
            HOSTRGB_SIDE_LOGO_COUNT as u32
        );
        assert_eq!(
            parse_define("HOSTRGB_DEADLINE_UNIT_MS"),
            HOSTRGB_DEADLINE_UNIT_MS
        );
        assert_eq!(
            parse_define("HOSTRGB_SUB_REJECTED"),
            HOSTRGB_SUB_REJECTED as u32
        );
    }
}
