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
    ///
    /// Bounded like the read half (KTD7): an implementation that could block
    /// indefinitely must give up and report an I/O failure instead.
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

/// Bound on the write half of one round trip, in milliseconds.
///
/// The node is put in non-blocking mode so a full kernel buffer surfaces as an
/// error rather than a blocked thread; a write is then retried only inside this
/// window, and crossing it is an I/O failure like a read timeout (KTD7, KTD12).
#[cfg(feature = "daemon")]
pub const HID_WRITE_TIMEOUT_MS: u32 = crate::device_state::COMMAND_WRITE_ALLOWANCE_MS;

/// How long a bounded write sleeps between retries inside its window.
#[cfg(feature = "daemon")]
const HID_WRITE_RETRY_INTERVAL: Duration = Duration::from_micros(200);

#[cfg(feature = "daemon")]
pub struct HidTransport {
    device: hidapi::HidDevice,
    write_timeout_ms: u32,
}

#[cfg(feature = "daemon")]
impl HidTransport {
    /// Wrap an opened `hidapi::HidDevice` with the default write bound.
    pub fn new(device: hidapi::HidDevice) -> Self {
        Self::with_write_timeout(device, HID_WRITE_TIMEOUT_MS)
    }

    /// Wrap an opened `hidapi::HidDevice` with an explicit write bound.
    ///
    /// Non-blocking mode does not affect `read_timeout`, which polls with its own
    /// deadline either way; it only keeps `write` from parking the render thread.
    pub fn with_write_timeout(device: hidapi::HidDevice, write_timeout_ms: u32) -> Self {
        if let Err(err) = device.set_blocking_mode(false) {
            log::warn!(
                "could not put the Gem80 node in non-blocking mode ({err}); \
                 writes fall back to the kernel's own bound"
            );
        }
        Self {
            device,
            write_timeout_ms,
        }
    }
}

#[cfg(feature = "daemon")]
impl Transport for HidTransport {
    fn write_payload(&mut self, payload: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
        // Prepend Report ID 0x00 for unnumbered reports.
        let mut buf = [0u8; PAYLOAD_SIZE + 1];
        buf[0] = 0x00;
        buf[1..].copy_from_slice(payload);

        let deadline = Instant::now() + Duration::from_millis(u64::from(self.write_timeout_ms));
        loop {
            let last_error = match self.device.write(&buf) {
                Ok(0) => "hidapi write returned 0 bytes".to_string(),
                Ok(_) => return Ok(()),
                Err(e) => format!("hidapi write failed: {e}"),
            };
            // A non-blocking node refuses a write whose buffer is momentarily
            // full, so one retry inside the window costs less than the node
            // reopen, reprobe and full repaint a hard failure sets off.
            if Instant::now() >= deadline {
                log::debug!(
                    "giving up on a Gem80 write after {} ms: {last_error}",
                    self.write_timeout_ms
                );
                return Err(DeviceError::Timeout {
                    timeout_ms: self.write_timeout_ms,
                });
            }
            std::thread::sleep(HID_WRITE_RETRY_INTERVAL);
        }
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

/// Whether an enumerated HID interface is the Gem80 host-RGB interface.
///
/// Matches on VID, PID, usage page, and usage. A usage of 0 is accepted because some
/// platforms report it that way for the vendor-defined collection.
#[cfg(feature = "daemon")]
pub fn is_gem80_interface(device: &hidapi::DeviceInfo) -> bool {
    use crate::device::protocol::{
        HOSTRGB_PRODUCT_ID, HOSTRGB_USAGE, HOSTRGB_USAGE_PAGE, HOSTRGB_VENDOR_ID,
    };

    device.vendor_id() == HOSTRGB_VENDOR_ID
        && device.product_id() == HOSTRGB_PRODUCT_ID
        && device.usage_page() == HOSTRGB_USAGE_PAGE
        && (device.usage() == HOSTRGB_USAGE || device.usage() == 0)
}

/// Non-blocking device enumeration to find and open the Gem80 raw HID interface.
/// Scans the available devices for matching VID, PID, Usage Page, and Usage.
/// Returns `Ok(Some(transport))` if found and opened, or `Ok(None)` if absent.
/// Does not block or sleep in a retry loop.
#[cfg(feature = "daemon")]
pub fn find_gem80_device(api: &mut hidapi::HidApi) -> Result<Option<HidTransport>, DeviceError> {
    if let Err(e) = api.refresh_devices() {
        return Err(DeviceError::Io(format!("refresh_devices failed: {e}")));
    }

    let target_path = api
        .device_list()
        .find(|d| is_gem80_interface(d))
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
    /// LED geometry to report in PROBE responses as `(count, per packet, side first)`.
    pub reported_geometry: (u8, u8, u8),
    /// Incoming response queue.
    pub rx_queue: VecDeque<[u8; PAYLOAD_SIZE]>,
    /// If true, writes will not enqueue any responses, causing all subsequent reads to time out.
    pub drop_responses: bool,
    /// If true, commands take effect but their answers never reach the host.
    ///
    /// Distinct from `drop_responses`, which models a device that stopped
    /// listening: this one models a lost response to a command the firmware
    /// already applied, which is how a MODE can be held with nobody watching it.
    pub swallow_responses: bool,
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
            reported_geometry: (
                HOSTRGB_LED_COUNT as u8,
                HOSTRGB_LEDS_PER_PACKET as u8,
                HOSTRGB_SIDE_FIRST as u8,
            ),
            rx_queue: VecDeque::new(),
            drop_responses: false,
            swallow_responses: false,
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

    /// Reclaim the regions once the deadline has passed.
    ///
    /// The real firmware does this from `housekeeping_task_user()` on every main
    /// loop tick, independent of host traffic, so the check cannot be reached only
    /// from HEARTBEAT handling: a fake that is more forgiving than the hardware
    /// hides watchdog bugs instead of catching them.
    fn sweep_deadline(&mut self) {
        if self.regions != 0 && self.is_deadline_passed() {
            self.regions = 0;
            self.deadline_ms = 0;
        }
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

        // Every command handler runs after a loop tick on real hardware, so the
        // deadline is already reclaimed by the time the command is dispatched.
        self.sweep_deadline();

        let sub = payload[1];
        let response = match sub {
            HOSTRGB_SUB_PROBE => {
                let mut resp = [0u8; PAYLOAD_SIZE];
                resp[0] = HOSTRGB_CMD;
                resp[1] = HOSTRGB_SUB_PROBE;
                resp[2] = self.protocol_revision;
                let (led_count, leds_per_packet, side_first) = self.reported_geometry;
                resp[3] = led_count;
                resp[4] = leds_per_packet;
                resp[5] = side_first;
                resp
            }
            HOSTRGB_SUB_MODE => {
                let mask = payload[2];
                let mut resp = *payload;

                if mask & !HOSTRGB_REGION_ALL != 0 {
                    // Unknown bits rejected
                    resp[1] |= HOSTRGB_SUB_REJECTED;
                } else if mask != 0 {
                    let deadline_units = u16::from_le_bytes([payload[3], payload[4]]);
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
                resp
            }
            HOSTRGB_SUB_SET => {
                // A SET that arrives once the watchdog has taken the regions back
                // paints nothing the keyboard shows, and still answers: the
                // firmware acknowledges it and leaves the user's stored effect up.
                if self.regions != 0 {
                    let start = payload[2] as usize;
                    let count = std::cmp::min(payload[3] as usize, HOSTRGB_LEDS_PER_PACKET);
                    for i in 0..count {
                        let led = start + i;
                        if led < HOSTRGB_LED_COUNT {
                            self.led_buffer[led] =
                                (payload[4 + i * 3], payload[5 + i * 3], payload[6 + i * 3]);
                        }
                    }
                }
                *payload
            }
            HOSTRGB_SUB_HEARTBEAT => {
                let deadline_units = u16::from_le_bytes([payload[2], payload[3]]);
                let mut resp = *payload;

                // The sweep above already reclaimed a passed deadline, so a
                // heartbeat that arrives late finds no regions left to extend.
                if deadline_units != 0 && self.regions != 0 {
                    self.deadline_ms = (deadline_units as u32) * HOSTRGB_DEADLINE_UNIT_MS;
                    self.armed_at = self.now();
                } else {
                    resp[1] |= HOSTRGB_SUB_REJECTED;
                }
                resp
            }
            _ => {
                // Unknown subcommand
                let mut resp = *payload;
                resp[1] |= HOSTRGB_SUB_REJECTED;
                resp
            }
        };

        if !self.swallow_responses {
            self.rx_queue.push_back(response);
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

    /// Enters direct mode on a fresh transport with a fixed simulated clock.
    fn enter_direct_mode(deadline_ms: u32) -> FakeTransport {
        let mut transport = FakeTransport::new();
        transport.simulated_now = Some(Instant::now());
        let mode_req = build_mode_packet(HOSTRGB_REGION_ALL, deadline_ms).unwrap();
        transport.write_payload(&mode_req).unwrap();
        let resp = transport.read_payload_timeout(100).unwrap();
        parse_mode_response(&resp).unwrap();
        assert_eq!(transport.regions, HOSTRGB_REGION_ALL);
        transport
    }

    #[test]
    fn test_fake_transport_set_updates_led_buffer() {
        let mut transport = enter_direct_mode(300);
        let colors = [(255, 0, 128), (0, 255, 64), (10, 20, 30)];
        let set_req = build_set_packet(88, &colors).unwrap();
        transport.write_payload(&set_req).unwrap();
        let resp = transport.read_payload_timeout(100).unwrap();
        parse_set_response(&resp).unwrap();

        assert_eq!(transport.led_buffer[88], (255, 0, 128));
        assert_eq!(transport.led_buffer[89], (0, 255, 64));
        assert_eq!(transport.led_buffer[90], (10, 20, 30));
    }

    /// Test scenario: 마감이 지나면 하트비트를 기다리지 않고 리전이 회수되고, 그 뒤에 온
    /// `SET`은 응답만 받고 조용히 버려진다 (D1).
    #[test]
    fn test_set_after_the_deadline_is_discarded_without_a_heartbeat() {
        let mut transport = enter_direct_mode(300);
        let before = transport.led_buffer[0];

        // No heartbeat and no other traffic: the deadline simply passes.
        transport.advance_time(Duration::from_millis(301));

        let set_req = build_set_packet(0, &[(7, 7, 7)]).unwrap();
        transport.write_payload(&set_req).unwrap();
        let resp = transport.read_payload_timeout(100).unwrap();
        parse_set_response(&resp).expect("the firmware still acknowledges the packet");

        assert_eq!(
            transport.regions, 0,
            "the watchdog reclaims the regions at the SET, not only at a heartbeat"
        );
        assert_eq!(
            transport.led_buffer[0], before,
            "a SET past the deadline must paint nothing"
        );
        assert_eq!(transport.deadline_ms, 0);
    }

    /// Test scenario: 명령은 적용되었는데 응답만 유실된 경우를 모형화한다 (B3).
    #[test]
    fn test_swallowed_response_still_applies_the_command() {
        let mut transport = FakeTransport::new();
        transport.swallow_responses = true;

        let mode_req = build_mode_packet(HOSTRGB_REGION_ALL, 300).unwrap();
        transport.write_payload(&mode_req).unwrap();

        assert_eq!(
            transport.regions, HOSTRGB_REGION_ALL,
            "the firmware applies MODE before it answers"
        );
        assert_eq!(
            transport.read_payload_timeout(5).unwrap_err(),
            DeviceError::Timeout { timeout_ms: 5 },
            "the answer never reaches the host"
        );
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
