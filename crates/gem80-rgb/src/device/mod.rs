//! Raw HID transport and Gem80 0x60 protocol handling.

pub mod protocol;
pub mod transport;

pub use protocol::*;
pub use transport::*;

/// High-level device handle for communicating with a NuPhy Gem80 keyboard via raw HID.
///
/// Encapsulates the 0x60 request-response protocol over an abstract `Transport`.
/// Every command writes a 32-byte packet and immediately awaits its 32-byte response
/// with a mandatory timeout (KTD1, KTD7). No write-only paths exist.
#[derive(Debug)]
pub struct Gem80Device<T: Transport> {
    transport: T,
}

impl<T: Transport> Gem80Device<T> {
    /// Create a new device handle wrapping the given transport.
    pub fn new(transport: T) -> Self {
        Self { transport }
    }

    /// Access the underlying transport.
    pub fn transport(&self) -> &T {
        &self.transport
    }

    /// Mutably access the underlying transport.
    pub fn transport_mut(&mut self) -> &mut T {
        &mut self.transport
    }

    /// Consume the handle and return the underlying transport.
    pub fn into_transport(self) -> T {
        self.transport
    }

    /// Query the keyboard firmware via PROBE (0x60 0x00).
    ///
    /// Returns the decoded `ProbeResponse` on success, or an error if
    /// the response times out, the subcommand is rejected, or the protocol revision is incompatible.
    pub fn probe(&mut self, timeout_ms: u32) -> Result<ProbeResponse, DeviceError> {
        let packet = build_probe_packet();
        let resp = self.transport.exchange(&packet, timeout_ms)?;
        parse_probe_response(&resp)
    }

    /// Enter or configure direct mode via MODE (0x60 0x01).
    ///
    /// `mask` specifies the region bitmask (e.g. `HOSTRGB_REGION_ALL = 0x03`).
    /// `deadline_ms` is the watchdog deadline in milliseconds (must be > 0 if `mask != 0`).
    pub fn set_mode(
        &mut self,
        mask: u8,
        deadline_ms: u32,
        timeout_ms: u32,
    ) -> Result<(), DeviceError> {
        let packet = build_mode_packet(mask, deadline_ms)?;
        let resp = self.transport.exchange(&packet, timeout_ms)?;
        parse_mode_response(&resp)
    }

    /// Exit direct mode and restore user's stored RGB effect via MODE (0x60 0x01, mask=0, deadline=0).
    pub fn exit_direct_mode(&mut self, timeout_ms: u32) -> Result<(), DeviceError> {
        let packet = build_mode_packet(0, 0)?;
        let resp = self.transport.exchange(&packet, timeout_ms)?;
        parse_mode_response(&resp)
    }

    /// Update up to 9 LEDs starting at `start` via SET (0x60 0x02).
    pub fn set_leds(
        &mut self,
        start: u8,
        colors: &[(u8, u8, u8)],
        timeout_ms: u32,
    ) -> Result<(), DeviceError> {
        let packet = build_set_packet(start, colors)?;
        let resp = self.transport.exchange(&packet, timeout_ms)?;
        parse_set_response(&resp)
    }

    /// Send a watchdog HEARTBEAT (0x60 0x03) before the previous deadline expires.
    ///
    /// `deadline_ms` is the new watchdog deadline in milliseconds.
    pub fn heartbeat(&mut self, deadline_ms: u32, timeout_ms: u32) -> Result<(), DeviceError> {
        let packet = build_heartbeat_packet(deadline_ms)?;
        let resp = self.transport.exchange(&packet, timeout_ms)?;
        parse_heartbeat_response(&resp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn test_device_probe_success() {
        let transport = FakeTransport::new();
        let mut dev = Gem80Device::new(transport);
        let probe = dev.probe(100).expect("probe must succeed");
        assert_eq!(probe.protocol, 2);
        assert_eq!(probe.led_count, 101);
        assert_eq!(probe.leds_per_packet, 9);
        assert_eq!(probe.side_first, 89);
        assert!(probe.is_compatible());
    }

    #[test]
    fn test_device_probe_incompatible_revision() {
        let mut transport = FakeTransport::new();
        transport.protocol_revision = 1; // Revision 1
        let mut dev = Gem80Device::new(transport);
        let err = dev.probe(100).unwrap_err();
        assert_eq!(
            err,
            DeviceError::IncompatibleProtocol {
                expected: 2,
                actual: 1,
            }
        );
    }

    #[test]
    fn test_device_direct_mode_lifecycle() {
        let transport = FakeTransport::new();
        let mut dev = Gem80Device::new(transport);

        // Enter direct mode with deadline 300 ms
        dev.set_mode(HOSTRGB_REGION_ALL, 300, 100)
            .expect("set_mode must succeed");
        assert_eq!(dev.transport().regions, HOSTRGB_REGION_ALL);
        assert_eq!(dev.transport().deadline_ms, 300);

        // Heartbeat at 150 ms
        dev.transport_mut().advance_time(Duration::from_millis(150));
        dev.heartbeat(300, 100).expect("heartbeat must succeed");
        assert_eq!(dev.transport().regions, HOSTRGB_REGION_ALL);

        // Exit direct mode
        dev.exit_direct_mode(100)
            .expect("exit_direct_mode must succeed");
        assert_eq!(dev.transport().regions, 0);
        assert_eq!(dev.transport().deadline_ms, 0);
    }

    #[test]
    fn test_all_commands_timeout_when_device_silent() {
        let mut transport = FakeTransport::new();
        transport.drop_responses = true; // Transport never replies
        let mut dev = Gem80Device::new(transport);

        let timeout = 20;

        // 1. probe
        let err_probe = dev.probe(timeout).unwrap_err();
        assert_eq!(
            err_probe,
            DeviceError::Timeout {
                timeout_ms: timeout
            }
        );

        // 2. set_mode
        let err_mode = dev.set_mode(HOSTRGB_REGION_ALL, 300, timeout).unwrap_err();
        assert_eq!(
            err_mode,
            DeviceError::Timeout {
                timeout_ms: timeout
            }
        );

        // 3. exit_direct_mode
        let err_exit = dev.exit_direct_mode(timeout).unwrap_err();
        assert_eq!(
            err_exit,
            DeviceError::Timeout {
                timeout_ms: timeout
            }
        );

        // 4. set_leds
        let err_set = dev.set_leds(0, &[(255, 255, 255)], timeout).unwrap_err();
        assert_eq!(
            err_set,
            DeviceError::Timeout {
                timeout_ms: timeout
            }
        );

        // 5. heartbeat
        let err_hb = dev.heartbeat(300, timeout).unwrap_err();
        assert_eq!(
            err_hb,
            DeviceError::Timeout {
                timeout_ms: timeout
            }
        );
    }

    #[test]
    fn test_heartbeat_rejection_after_deadline_passes() {
        let transport = FakeTransport::new();
        let mut dev = Gem80Device::new(transport);

        // Enter direct mode
        dev.set_mode(HOSTRGB_REGION_ALL, 200, 100).unwrap();
        assert_eq!(dev.transport().regions, HOSTRGB_REGION_ALL);

        // Advance simulated time past deadline (+250 ms)
        dev.transport_mut().advance_time(Duration::from_millis(250));

        // Heartbeat after deadline must be rejected AND revoke regions
        let err = dev.heartbeat(200, 100).unwrap_err();
        assert_eq!(
            err,
            DeviceError::CommandRejected {
                subcommand: HOSTRGB_SUB_HEARTBEAT
            }
        );
        assert_eq!(dev.transport().regions, 0);
    }
}
