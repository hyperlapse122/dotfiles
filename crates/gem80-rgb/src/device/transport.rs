//! HID transport abstraction and hidapi implementation.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::device::protocol::{
    DeviceError, HOSTRGB_CMD, HOSTRGB_DEADLINE_UNIT_MS, HOSTRGB_LEDS_PER_PACKET, HOSTRGB_LED_COUNT,
    HOSTRGB_PROTOCOL, HOSTRGB_REGION_ALL, HOSTRGB_SIDE_FIRST, HOSTRGB_SUB_HEARTBEAT,
    HOSTRGB_SUB_MODE, HOSTRGB_SUB_PROBE, HOSTRGB_SUB_REJECTED, HOSTRGB_SUB_SET, PAYLOAD_SIZE,
};

/// Abstract transport for sending and receiving raw 32-byte HID reports.
pub trait Transport: Send {
    /// Write a 32-byte payload to the device.
    fn write_payload(&mut self, payload: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError>;

    /// Read a 32-byte response from the device with a mandatory timeout in milliseconds.
    /// Returns `Err(DeviceError::Timeout)` if no response arrives within `timeout_ms`.
    fn read_payload_timeout(&mut self, timeout_ms: u32) -> Result<[u8; PAYLOAD_SIZE], DeviceError>;

    /// Convenience helper to send a payload and immediately wait for its 32-byte response.
    fn exchange(
        &mut self,
        payload: &[u8; PAYLOAD_SIZE],
        timeout_ms: u32,
    ) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
        self.write_payload(payload)?;
        self.read_payload_timeout(timeout_ms)
    }
}

// --- hidapi transport implementation (daemon feature) ---

#[cfg(feature = "daemon")]
pub struct HidTransport {
    device: hidapi::HidDevice,
}

#[cfg(feature = "daemon")]
impl HidTransport {
    /// Wrap an opened `hidapi::HidDevice`.
    pub fn new(device: hidapi::HidDevice) -> Self {
        Self { device }
    }
}

#[cfg(feature = "daemon")]
impl Transport for HidTransport {
    fn write_payload(&mut self, payload: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
        // Prepend Report ID 0x00 for unnumbered reports.
        let mut buf = [0u8; PAYLOAD_SIZE + 1];
        buf[0] = 0x00;
        buf[1..].copy_from_slice(payload);

        let written = self
            .device
            .write(&buf)
            .map_err(|e| DeviceError::Io(format!("hidapi write failed: {e}")))?;

        if written == 0 {
            return Err(DeviceError::Io("hidapi write returned 0 bytes".to_string()));
        }
        Ok(())
    }

    fn read_payload_timeout(&mut self, timeout_ms: u32) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
        let mut buf = [0u8; PAYLOAD_SIZE];
        let n = self
            .device
            .read_timeout(&mut buf, timeout_ms as i32)
            .map_err(|e| DeviceError::Io(format!("hidapi read failed: {e}")))?;

        if n == 0 {
            return Err(DeviceError::Timeout { timeout_ms });
        }
        if n < PAYLOAD_SIZE {
            return Err(DeviceError::Io(format!(
                "hidapi short read: received {n} bytes, expected {PAYLOAD_SIZE}"
            )));
        }
        Ok(buf)
    }
}

/// Non-blocking device enumeration to find and open the Gem80 raw HID interface.
/// Scans the available devices for matching VID, PID, Usage Page, and Usage.
/// Returns `Ok(Some(transport))` if found and opened, or `Ok(None)` if absent.
/// Does not block or sleep in a retry loop.
#[cfg(feature = "daemon")]
pub fn find_gem80_device(api: &mut hidapi::HidApi) -> Result<Option<HidTransport>, DeviceError> {
    use crate::device::protocol::{
        HOSTRGB_PRODUCT_ID, HOSTRGB_USAGE, HOSTRGB_USAGE_PAGE, HOSTRGB_VENDOR_ID,
    };

    if let Err(e) = api.refresh_devices() {
        return Err(DeviceError::Io(format!("refresh_devices failed: {e}")));
    }

    let target_path = api
        .device_list()
        .find(|d| {
            d.vendor_id() == HOSTRGB_VENDOR_ID
                && d.product_id() == HOSTRGB_PRODUCT_ID
                && d.usage_page() == HOSTRGB_USAGE_PAGE
                && (d.usage() == HOSTRGB_USAGE || d.usage() == 0)
        })
        .map(|d| d.path().to_owned());

    match target_path {
        Some(path) => match api.open_path(&path) {
            Ok(dev) => Ok(Some(HidTransport::new(dev))),
            Err(e) => Err(DeviceError::Io(format!(
                "failed to open {}: {e}",
                path.to_string_lossy()
            ))),
        },
        None => Ok(None),
    }
}

// --- Fake transport for testing firmware behavior without hardware ---

/// Simulated firmware state machine faithfully reproducing `firmware/nuphy-gem80-hostrgb/keymap/keymap.c`.
#[derive(Debug, Clone)]
pub struct FakeTransport {
    /// Currently held region mask (0 = none, 1 = KEYS, 2 = SIDE, 3 = ALL).
    pub regions: u8,
    /// Watchdog deadline in milliseconds (0 = disarmed).
    pub deadline_ms: u32,
    /// Instant when deadline was armed.
    pub armed_at: Instant,
    /// Virtual current time, if overridden for deterministic test advancement.
    pub simulated_now: Option<Instant>,
    /// Frame buffer storing 101 RGB pixels.
    pub led_buffer: [(u8, u8, u8); HOSTRGB_LED_COUNT],
    /// Protocol revision to report in PROBE responses (default: 2).
    pub protocol_revision: u8,
    /// Incoming response queue.
    pub rx_queue: VecDeque<[u8; PAYLOAD_SIZE]>,
    /// If true, writes will not enqueue any responses, causing all subsequent reads to time out.
    pub drop_responses: bool,
}

impl Default for FakeTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl FakeTransport {
    /// Create a new `FakeTransport` with clean initial state.
    pub fn new() -> Self {
        Self {
            regions: 0,
            deadline_ms: 0,
            armed_at: Instant::now(),
            simulated_now: None,
            led_buffer: [(0, 0, 0); HOSTRGB_LED_COUNT],
            protocol_revision: HOSTRGB_PROTOCOL,
            rx_queue: VecDeque::new(),
            drop_responses: false,
        }
    }

    /// Return current simulated or real time.
    pub fn now(&self) -> Instant {
        self.simulated_now.unwrap_or_else(Instant::now)
    }

    /// Advance simulated time by `duration`.
    pub fn advance_time(&mut self, duration: Duration) {
        let current = self.now();
        self.simulated_now = Some(current + duration);
    }

    /// Check whether the watchdog deadline has elapsed.
    pub fn is_deadline_passed(&self) -> bool {
        if self.deadline_ms == 0 {
            return false;
        }
        let elapsed = self.now().saturating_duration_since(self.armed_at);
        elapsed.as_millis() >= self.deadline_ms as u128
    }

    /// Explicitly inject a raw packet into the receive queue.
    pub fn queue_response(&mut self, packet: [u8; PAYLOAD_SIZE]) {
        self.rx_queue.push_back(packet);
    }
}

impl Transport for FakeTransport {
    fn write_payload(&mut self, payload: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
        if self.drop_responses {
            return Ok(());
        }

        if payload[0] != HOSTRGB_CMD {
            return Ok(());
        }

        let sub = payload[1];
        match sub {
            HOSTRGB_SUB_PROBE => {
                let mut resp = [0u8; PAYLOAD_SIZE];
                resp[0] = HOSTRGB_CMD;
                resp[1] = HOSTRGB_SUB_PROBE;
                resp[2] = self.protocol_revision;
                resp[3] = HOSTRGB_LED_COUNT as u8;
                resp[4] = HOSTRGB_LEDS_PER_PACKET as u8;
                resp[5] = HOSTRGB_SIDE_FIRST as u8;
                self.rx_queue.push_back(resp);
            }
            HOSTRGB_SUB_MODE => {
                let mask = payload[2];
                let mut resp = *payload;

                if mask & !HOSTRGB_REGION_ALL != 0 {
                    // Unknown bits rejected
                    resp[1] |= HOSTRGB_SUB_REJECTED;
                } else if mask != 0 {
                    let deadline_units = (payload[3] as u16) | ((payload[4] as u16) << 8);
                    if deadline_units != 0 {
                        self.regions = mask;
                        self.deadline_ms = (deadline_units as u32) * HOSTRGB_DEADLINE_UNIT_MS;
                        self.armed_at = self.now();
                    } else {
                        // Mask != 0 but zero deadline is rejected
                        resp[1] |= HOSTRGB_SUB_REJECTED;
                    }
                } else {
                    // Exit direct mode (mask == 0)
                    self.regions = 0;
                    self.deadline_ms = 0;
                }
                self.rx_queue.push_back(resp);
            }
            HOSTRGB_SUB_SET => {
                let start = payload[2] as usize;
                let count = std::cmp::min(payload[3] as usize, HOSTRGB_LEDS_PER_PACKET);
                for i in 0..count {
                    let led = start + i;
                    if led < HOSTRGB_LED_COUNT {
                        self.led_buffer[led] =
                            (payload[4 + i * 3], payload[5 + i * 3], payload[6 + i * 3]);
                    }
                }
                self.rx_queue.push_back(*payload);
            }
            HOSTRGB_SUB_HEARTBEAT => {
                let deadline_units = (payload[2] as u16) | ((payload[3] as u16) << 8);
                let mut resp = *payload;
                let passed = self.is_deadline_passed();

                if deadline_units != 0 && self.regions != 0 && !passed {
                    self.deadline_ms = (deadline_units as u32) * HOSTRGB_DEADLINE_UNIT_MS;
                    self.armed_at = self.now();
                } else {
                    // Goal Capsule: Rejects heartbeat arriving after deadline AND revokes regions on the spot
                    if self.regions != 0 && passed {
                        self.regions = 0;
                        self.deadline_ms = 0;
                    }
                    resp[1] |= HOSTRGB_SUB_REJECTED;
                }
                self.rx_queue.push_back(resp);
            }
            _ => {
                // Unknown subcommand
                let mut resp = *payload;
                resp[1] |= HOSTRGB_SUB_REJECTED;
                self.rx_queue.push_back(resp);
            }
        }

        Ok(())
    }

    fn read_payload_timeout(&mut self, timeout_ms: u32) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
        self.rx_queue
            .pop_front()
            .ok_or(DeviceError::Timeout { timeout_ms })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::protocol::{
        build_heartbeat_packet, build_mode_packet, build_probe_packet, build_set_packet,
        parse_heartbeat_response, parse_mode_response, parse_probe_response, parse_set_response,
        HOSTRGB_REGION_ALL,
    };

    #[test]
    fn test_fake_transport_probe_behavior() {
        let mut transport = FakeTransport::new();
        let probe_req = build_probe_packet();
        transport.write_payload(&probe_req).unwrap();
        let resp = transport.read_payload_timeout(100).unwrap();
        let probe = parse_probe_response(&resp).unwrap();
        assert_eq!(probe.protocol, 2);
        assert_eq!(probe.led_count, 101);
        assert_eq!(probe.leds_per_packet, 9);
        assert_eq!(probe.side_first, 89);
    }

    #[test]
    fn test_fake_transport_watchdog_deadline_and_heartbeat_rejection() {
        let mut transport = FakeTransport::new();
        let start_time = Instant::now();
        transport.simulated_now = Some(start_time);

        // Enter direct mode with deadline = 300 ms
        let mode_req = build_mode_packet(HOSTRGB_REGION_ALL, 300).unwrap();
        transport.write_payload(&mode_req).unwrap();
        let resp = transport.read_payload_timeout(100).unwrap();
        parse_mode_response(&resp).unwrap();
        assert_eq!(transport.regions, HOSTRGB_REGION_ALL);
        assert_eq!(transport.deadline_ms, 300);

        // Send heartbeat within deadline (at +150 ms)
        transport.advance_time(Duration::from_millis(150));
        assert!(!transport.is_deadline_passed());
        let hb_req = build_heartbeat_packet(300).unwrap();
        transport.write_payload(&hb_req).unwrap();
        let hb_resp = transport.read_payload_timeout(100).unwrap();
        parse_heartbeat_response(&hb_resp).expect("heartbeat before deadline must succeed");
        assert_eq!(transport.regions, HOSTRGB_REGION_ALL);

        // Advance time past deadline (+350 ms from re-arm)
        transport.advance_time(Duration::from_millis(350));
        assert!(transport.is_deadline_passed());

        // Send heartbeat after deadline passed: must be rejected AND revoke regions on the spot
        transport.write_payload(&hb_req).unwrap();
        let late_resp = transport.read_payload_timeout(100).unwrap();
        let err = parse_heartbeat_response(&late_resp).unwrap_err();
        assert_eq!(
            err,
            DeviceError::CommandRejected {
                subcommand: HOSTRGB_SUB_HEARTBEAT
            }
        );
        assert_eq!(
            transport.regions, 0,
            "Regions must be revoked on the spot when late heartbeat arrives"
        );
    }

    #[test]
    fn test_fake_transport_exit_direct_mode() {
        let mut transport = FakeTransport::new();
        // Enter direct mode
        let mode_req = build_mode_packet(HOSTRGB_REGION_ALL, 200).unwrap();
        transport.write_payload(&mode_req).unwrap();
        let _ = transport.read_payload_timeout(100).unwrap();
        assert_eq!(transport.regions, HOSTRGB_REGION_ALL);

        // Exit direct mode (mask == 0)
        let exit_req = build_mode_packet(0, 0).unwrap();
        transport.write_payload(&exit_req).unwrap();
        let exit_resp = transport.read_payload_timeout(100).unwrap();
        parse_mode_response(&exit_resp).unwrap();
        assert_eq!(transport.regions, 0);
        assert_eq!(transport.deadline_ms, 0);
    }

    #[test]
    fn test_fake_transport_timeout_when_responses_dropped() {
        let mut transport = FakeTransport::new();
        transport.drop_responses = true;

        let probe_req = build_probe_packet();
        transport.write_payload(&probe_req).unwrap();
        let err = transport.read_payload_timeout(50).unwrap_err();
        assert_eq!(err, DeviceError::Timeout { timeout_ms: 50 });
    }

    #[test]
    fn test_fake_transport_set_updates_led_buffer() {
        let mut transport = FakeTransport::new();
        let colors = [(255, 0, 128), (0, 255, 64), (10, 20, 30)];
        let set_req = build_set_packet(88, &colors).unwrap();
        transport.write_payload(&set_req).unwrap();
        let resp = transport.read_payload_timeout(100).unwrap();
        parse_set_response(&resp).unwrap();

        assert_eq!(transport.led_buffer[88], (255, 0, 128));
        assert_eq!(transport.led_buffer[89], (0, 255, 64));
        assert_eq!(transport.led_buffer[90], (10, 20, 30));
    }

    #[test]
    #[cfg(feature = "daemon")]
    fn test_device_enumeration_nonblocking_when_absent() {
        // Calling find_gem80_device when keyboard is absent returns immediately with Ok(None)
        if let Ok(mut api) = hidapi::HidApi::new() {
            let start = Instant::now();
            let result = find_gem80_device(&mut api);
            let elapsed = start.elapsed();
            assert!(
                elapsed < Duration::from_millis(500),
                "Device search must return immediately, not block for seconds"
            );
            // Result is either Ok(None) or Ok(Some(dev)) if plugged in
            assert!(result.is_ok());
        }
    }
}
