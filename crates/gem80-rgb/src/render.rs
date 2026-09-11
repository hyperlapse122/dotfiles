//! Render loop, tick scheduling, and device output thread.
//!
//! The render thread is the sole owner of the HID device (KTD7). Every tick it
//! drains the boundary channel, sweeps layer lifetimes, advances the device state
//! machine, and writes the difference between the composed frame and the hardware
//! mirror (R9). A write that spans several packets drains connection cleanups
//! between packets — those are O(1) and cannot wait (R13) — while requests that
//! change the composite wait for the next tick boundary, so the packets in flight
//! still describe the frame they were planned from and the round trips they cost
//! stay inside `F_budget` (C1, KTD12).
//!
//! Nothing here blocks without a bound: every device command carries a read
//! timeout, and enumeration is a non-blocking scan. A tick runs to completion with
//! no device attached, which is what keeps the socket and the compositor alive
//! while the keyboard is away (R2).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use crate::compositor::{Color, Compositor, LedDiff};
use crate::device::protocol::{
    DeviceError, HOSTRGB_LEDS_PER_PACKET, HOSTRGB_LED_COUNT, HOSTRGB_PROTOCOL, HOSTRGB_REGION_ALL,
    HOSTRGB_SIDE_FIRST,
};
use crate::device::{Gem80Device, Transport};
use crate::device_state::{transition, DeviceEvent, DeviceStateKind, ProbeBackoff, Timing};
use crate::server::{apply_boundary_message, BoundaryReceiver};
use crate::wire::GEM80_TOTAL_LEDS;

/// Upper bound on state transitions resolved inside a single tick.
///
/// `Absent -> Probing -> Entering -> DirectAll` is three, so one tick can take a
/// freshly appeared keyboard all the way to a full frame. The bound stops a
/// pathological firmware from spinning the tick forever.
const MAX_TRANSITIONS_PER_TICK: usize = 4;

/// Where the render thread gets its device from.
///
/// Both calls are non-blocking: a missing keyboard answers immediately so the tick
/// keeps its period (KTD7, R2).
pub trait DeviceSource {
    /// The transport this source hands out.
    type Transport: Transport;

    /// Whether enumeration currently lists a matching device. Opens nothing, which
    /// is what lets `Incompatible` watch for the device without probing it (KTD9).
    fn is_present(&mut self) -> bool;

    /// Opens the device node, or `Ok(None)` when enumeration does not list it.
    fn open(&mut self) -> Result<Option<Self::Transport>, DeviceError>;
}

/// Enumerates and opens the real Gem80 raw HID interface through `hidapi`.
pub struct HidDeviceSource {
    api: Option<hidapi::HidApi>,
}

impl HidDeviceSource {
    /// Creates the source, tolerating an `hidapi` that cannot initialise yet.
    ///
    /// A failed init is not a fatal daemon error: the socket still opens and the
    /// compositor still runs (R2). Every later call retries the init.
    pub fn new() -> Self {
        Self {
            api: hidapi::HidApi::new().ok(),
        }
    }

    fn api(&mut self) -> Option<&mut hidapi::HidApi> {
        if self.api.is_none() {
            self.api = hidapi::HidApi::new().ok();
        }
        self.api.as_mut()
    }
}

impl Default for HidDeviceSource {
    fn default() -> Self {
        Self::new()
    }
}

impl DeviceSource for HidDeviceSource {
    type Transport = crate::device::HidTransport;

    fn is_present(&mut self) -> bool {
        let Some(api) = self.api() else {
            return false;
        };
        if api.refresh_devices().is_err() {
            return false;
        }
        api.device_list().any(crate::device::is_gem80_interface)
    }

    fn open(&mut self) -> Result<Option<Self::Transport>, DeviceError> {
        match self.api() {
            Some(api) => crate::device::find_gem80_device(api),
            None => Ok(None),
        }
    }
}

/// One SET packet: a start index and the colours that follow it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedPacket {
    /// Index of the first LED in the packet.
    pub start: u8,
    /// Up to `HOSTRGB_LEDS_PER_PACKET` consecutive colours.
    pub colors: Vec<(u8, u8, u8)>,
}

/// Turns a diff into SET packets, capped at the cost of a full repaint.
///
/// Consecutive changed LEDs share a packet, and unchanged LEDs inside a nine-LED
/// window ride along rather than starting a new round trip. A diff so scattered
/// that it would need more packets than a full repaint is sent as a full repaint
/// instead — that cap is what keeps the worst-case sparse update inside `F_budget`
/// (KTD12).
pub fn plan_packets(
    diff: &[LedDiff],
    frame: &[Color; GEM80_TOTAL_LEDS],
    max_frame_packets: usize,
) -> Vec<LedPacket> {
    let mut packets = Vec::new();
    let mut i = 0;
    while i < diff.len() {
        let start = diff[i].led_index;
        let mut end = start;
        while i < diff.len() && diff[i].led_index < start + HOSTRGB_LEDS_PER_PACKET {
            end = diff[i].led_index;
            i += 1;
        }
        packets.push(LedPacket {
            start: start as u8,
            colors: frame[start..=end].iter().map(|c| (c.r, c.g, c.b)).collect(),
        });
    }

    // The cap comes from the caller's own timing, never from the default
    // constants: `F_budget` is computed from the same field, so reading a
    // different one here would void KTD12's invariant without any test noticing.
    if packets.len() > max_frame_packets {
        return full_frame_packets(frame);
    }
    packets
}

/// Splits the whole 101-LED frame into packets of nine (KTD3).
pub fn full_frame_packets(frame: &[Color; GEM80_TOTAL_LEDS]) -> Vec<LedPacket> {
    let mut packets = Vec::new();
    let mut offset = 0;
    while offset < HOSTRGB_LED_COUNT {
        let end = std::cmp::min(offset + HOSTRGB_LEDS_PER_PACKET, HOSTRGB_LED_COUNT);
        packets.push(LedPacket {
            start: offset as u8,
            colors: frame[offset..end].iter().map(|c| (c.r, c.g, c.b)).collect(),
        });
        offset = end;
    }
    packets
}

/// Counters the render thread keeps for tests and for operator visibility.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RenderStats {
    /// Ticks completed, device attached or not.
    pub ticks: u64,
    /// Frame writes that sent at least one packet.
    pub frames_written: u64,
    /// SET packets written.
    pub packets_written: u64,
    /// LEDs written, summed over packets.
    pub leds_written: u64,
    /// Frame writes that covered all 101 LEDs (KTD3, R23).
    pub full_repaints: u64,
    /// MODE(REGION_ALL) requests accepted, entry and every re-entry (R3).
    pub direct_mode_entries: u64,
    /// Heartbeats the firmware rejected (R3).
    pub heartbeat_rejections: u64,
    /// Probes sent. Stays flat while `Incompatible` (KTD9).
    pub probes_sent: u64,
    /// Enumeration scans performed.
    pub enumerations: u64,
}

/// The render thread: compositor, device, and the state machine between them.
pub struct RenderThread<S: DeviceSource> {
    compositor: Compositor,
    boundary: BoundaryReceiver,
    source: S,
    device: Option<Gem80Device<S::Transport>>,
    state: DeviceStateKind,
    timing: Timing,
    backoff: ProbeBackoff,
    retry_at: Option<Instant>,
    heartbeat_due: Option<Instant>,
    stats: RenderStats,
}

impl<S: DeviceSource> RenderThread<S> {
    /// Builds a render thread around an already configured compositor.
    pub fn new(compositor: Compositor, boundary: BoundaryReceiver, source: S) -> Self {
        Self::with_timing(compositor, boundary, source, Timing::DEFAULT)
    }

    /// Builds a render thread with explicit timing constants.
    pub fn with_timing(
        compositor: Compositor,
        boundary: BoundaryReceiver,
        source: S,
        timing: Timing,
    ) -> Self {
        debug_assert!(
            timing.invariant_holds(),
            "timing constants must satisfy KTD12: F_budget + T + jitter < D/2"
        );
        Self {
            compositor,
            boundary,
            source,
            device: None,
            state: DeviceStateKind::Absent,
            backoff: ProbeBackoff::from_timing(&timing),
            timing,
            retry_at: None,
            heartbeat_due: None,
            stats: RenderStats::default(),
        }
    }

    /// The current device state.
    pub fn state(&self) -> DeviceStateKind {
        self.state
    }

    /// The timing constants in force.
    pub fn timing(&self) -> &Timing {
        &self.timing
    }

    /// Counters accumulated so far.
    pub fn stats(&self) -> RenderStats {
        self.stats
    }

    /// The compositor, for status and tests.
    pub fn compositor(&self) -> &Compositor {
        &self.compositor
    }

    /// Runs one tick at `now`: boundary, lifetimes, device, frame.
    pub fn tick_at(&mut self, now: Instant) {
        self.stats.ticks += 1;
        self.drain_boundary();
        self.compositor.tick_at(now);
        self.advance_device(now);
        if self.state == DeviceStateKind::DirectAll {
            self.write_frame(now);
        }
    }

    /// Runs one tick against the real clock.
    pub fn tick(&mut self) {
        self.tick_at(Instant::now());
    }

    /// Ticks at the configured period until `shutdown` is set, then leaves direct
    /// mode before returning (R5).
    pub fn run(mut self, shutdown: &AtomicBool) {
        while !shutdown.load(Ordering::SeqCst) {
            let started = Instant::now();
            self.tick_at(started);
            let elapsed = started.elapsed();
            if elapsed < self.timing.tick_period {
                std::thread::sleep(self.timing.tick_period - elapsed);
            }
        }
        self.shutdown_device();
    }

    /// Leaves direct mode so the keyboard returns to its stored effect (R5, AE9).
    ///
    /// Only `DirectAll` owes the firmware a MODE(0); every other state just drops
    /// the node.
    pub fn shutdown_device(&mut self) {
        if self.state.holds_direct_mode() {
            if let Some(mut device) = self.device.take() {
                if let Err(err) = device.exit_direct_mode(self.timing.command_timeout_ms) {
                    log::warn!("leaving direct mode failed on shutdown: {err}");
                }
            }
        }
        self.device = None;
        self.state = DeviceStateKind::Absent;
        self.heartbeat_due = None;
    }

    /// Applies everything currently queued on the boundary channel (R13, R17).
    fn drain_boundary(&mut self) {
        let wire_state = self.state.to_wire();
        for message in self.boundary.drain() {
            apply_boundary_message(&mut self.compositor, wire_state, message);
        }
    }

    /// Applies only the connection cleanups waiting on reserved capacity (C1, R13).
    fn drain_cleanups(&mut self) {
        for connection in self.boundary.drain_cleanups() {
            self.compositor.remove_connection_layers(connection);
        }
    }

    /// Advances the state machine until it settles or the per-tick bound is hit.
    fn advance_device(&mut self, now: Instant) {
        for _ in 0..MAX_TRANSITIONS_PER_TICK {
            let Some(event) = self.poll_device(now) else {
                return;
            };
            self.apply_event(event, now);
        }
    }

    /// Performs this state's one piece of device work and reports what happened.
    fn poll_device(&mut self, now: Instant) -> Option<DeviceEvent> {
        match self.state {
            DeviceStateKind::Absent => self.poll_absent(now),
            DeviceStateKind::Probing => self.poll_probing(),
            DeviceStateKind::Incompatible => self.poll_incompatible(),
            DeviceStateKind::Entering => self.poll_entering(),
            DeviceStateKind::DirectAll => self.poll_direct_all(now),
        }
    }

    fn poll_absent(&mut self, now: Instant) -> Option<DeviceEvent> {
        if let Some(retry_at) = self.retry_at {
            if now < retry_at {
                return None;
            }
        }
        self.retry_at = None;
        self.stats.enumerations += 1;
        match self.source.open() {
            Ok(Some(transport)) => {
                self.device = Some(Gem80Device::new(transport));
                Some(DeviceEvent::Enumerated)
            }
            // A keyboard switched to wireless is absent for as long as the user
            // leaves it that way. Scanning every tick period would enumerate fifty
            // times a second, indefinitely, for an answer that will not change (B5).
            Ok(None) => {
                self.retry_at = Some(now + self.backoff.advance());
                None
            }
            Err(err) => {
                log::debug!("opening the Gem80 node failed: {err}");
                self.retry_at = Some(now + self.backoff.advance());
                None
            }
        }
    }

    fn poll_probing(&mut self) -> Option<DeviceEvent> {
        let mut device = self.device.take()?;
        self.stats.probes_sent += 1;
        let outcome = device.probe(self.timing.command_timeout_ms);
        self.device = Some(device);

        match outcome {
            Ok(probe) if probe.is_compatible() => Some(DeviceEvent::ProbeCompatible),
            // An explicit answer this daemon cannot drive — the wrong revision, or
            // the right revision over a geometry the renderer does not address — is
            // the one verdict that stops probing for good (R4, G3, KTD9).
            Ok(probe) => {
                log::warn!(
                    "Gem80 firmware reports revision {} with {} LEDs, {} per packet, side chain \
                     at {}; this daemon drives revision {HOSTRGB_PROTOCOL} with \
                     {HOSTRGB_LED_COUNT}/{HOSTRGB_LEDS_PER_PACKET}/{HOSTRGB_SIDE_FIRST}. Not \
                     entering direct mode.",
                    probe.protocol,
                    probe.led_count,
                    probe.leds_per_packet,
                    probe.side_first
                );
                Some(DeviceEvent::ProbeIncompatible)
            }
            Err(DeviceError::IncompatibleProtocol { expected, actual }) => {
                log::warn!(
                    "Gem80 firmware is revision {actual}, not the revision {expected} hostrgb \
                     build; not entering direct mode"
                );
                Some(DeviceEvent::ProbeIncompatible)
            }
            Err(DeviceError::CommandRejected { .. }) => Some(DeviceEvent::ProbeIncompatible),
            // Silence or I/O trouble may just be a device still booting (R4, AE15).
            Err(err) => {
                log::debug!("probe failed, retrying with backoff: {err}");
                Some(DeviceEvent::IoFailure)
            }
        }
    }

    fn poll_incompatible(&mut self) -> Option<DeviceEvent> {
        self.stats.enumerations += 1;
        if self.source.is_present() {
            None
        } else {
            Some(DeviceEvent::VanishedFromEnumeration)
        }
    }

    fn poll_entering(&mut self) -> Option<DeviceEvent> {
        let mut device = self.device.take()?;
        // v1 always asks for both regions at once (KTD2).
        let outcome = device.set_mode(
            HOSTRGB_REGION_ALL,
            self.timing.deadline_ms(),
            self.timing.command_timeout_ms,
        );
        self.device = Some(device);

        match outcome {
            Ok(()) => {
                self.stats.direct_mode_entries += 1;
                Some(DeviceEvent::ModeAccepted)
            }
            Err(err) => {
                log::debug!("entering direct mode failed: {err}");
                // The firmware applies MODE and only then answers, so a lost
                // answer leaves the keyboard in direct mode with nobody left to
                // heartbeat it: the host reads I/O failure and drops to `Absent`
                // while the device holds the regions until its watchdog fires.
                // MODE(0) here restores the stored effect straight away (B3, R5).
                if matches!(err, DeviceError::Timeout { .. } | DeviceError::Io(_)) {
                    self.exit_direct_mode_best_effort();
                }
                Some(DeviceEvent::IoFailure)
            }
        }
    }

    /// Asks the firmware to leave direct mode, logging rather than propagating.
    ///
    /// Used where the daemon is already on its way out of direct mode and the
    /// device may or may not still be listening.
    fn exit_direct_mode_best_effort(&mut self) {
        let timeout = self.timing.command_timeout_ms;
        if let Some(device) = self.device.as_mut() {
            if let Err(err) = device.exit_direct_mode(timeout) {
                log::debug!("the MODE(0) cleanup did not get through: {err}");
            }
        }
    }

    fn poll_direct_all(&mut self, now: Instant) -> Option<DeviceEvent> {
        match self.heartbeat_due {
            Some(due) if now >= due => {}
            Some(_) => return None,
            None => return None,
        }

        let mut device = self.device.take()?;
        let outcome = device.heartbeat(self.timing.deadline_ms(), self.timing.command_timeout_ms);
        self.device = Some(device);

        match outcome {
            Ok(()) => {
                self.heartbeat_due = Some(now + self.timing.heartbeat_interval);
                Some(DeviceEvent::HeartbeatAccepted)
            }
            // A rejected heartbeat means the firmware took the regions back (R3).
            Err(DeviceError::CommandRejected { .. }) => {
                self.stats.heartbeat_rejections += 1;
                Some(DeviceEvent::HeartbeatRejected)
            }
            Err(err) => {
                log::debug!("heartbeat failed: {err}");
                Some(DeviceEvent::IoFailure)
            }
        }
    }

    fn apply_event(&mut self, event: DeviceEvent, now: Instant) {
        let Some(step) = transition(self.state, event) else {
            return;
        };
        if step.invalidate_mirror {
            self.compositor.invalidate_mirror();
        }
        if step.close_node {
            self.device = None;
        }
        if step.reset_probe_backoff {
            self.backoff.reset();
            self.retry_at = None;
        }
        if step.grow_probe_backoff {
            self.retry_at = Some(now + self.backoff.advance());
        }
        self.state = step.next;
        match step.next {
            DeviceStateKind::DirectAll => {
                self.heartbeat_due = Some(now + self.timing.heartbeat_interval);
            }
            DeviceStateKind::Absent | DeviceStateKind::Incompatible => {
                self.heartbeat_due = None;
            }
            _ => {}
        }
    }

    /// Writes the difference between the composed frame and the hardware mirror.
    ///
    /// An invalid mirror makes the diff all 101 LEDs (KTD3). Connection cleanups
    /// are drained between packets, because they are O(1) and R13 does not let them
    /// wait; state-changing requests are not, so the packets still in flight keep
    /// describing the frame they were planned from (C1). A failed packet invalidates
    /// the mirror and drops to `Absent`, and the next successful write cycle sends
    /// all 101 LEDs again (R23).
    fn write_frame(&mut self, now: Instant) {
        let frame = self.compositor.compose();
        let diff = self.compositor.diff_against_mirror(&frame);
        if diff.is_empty() {
            return;
        }
        let was_invalid = !self.compositor.is_mirror_valid();
        let packets = plan_packets(&diff, &frame, self.timing.max_frame_packets);

        let Some(mut device) = self.device.take() else {
            return;
        };
        let mut failure = None;
        for packet in &packets {
            self.drain_cleanups();
            let outcome =
                device.set_leds(packet.start, &packet.colors, self.timing.command_timeout_ms);
            match outcome {
                Ok(()) => {
                    self.stats.packets_written += 1;
                    self.stats.leds_written += packet.colors.len() as u64;
                }
                Err(err) => {
                    log::warn!("frame packet at LED {} failed: {err}", packet.start);
                    failure = Some(err);
                    break;
                }
            }
        }
        self.device = Some(device);

        if failure.is_some() {
            self.apply_event(DeviceEvent::WriteFailure, now);
            return;
        }

        self.stats.frames_written += 1;
        if was_invalid {
            self.stats.full_repaints += 1;
        }
        self.compositor.commit_frame(frame);
    }
}

/// A running render thread and the flag that stops it.
pub struct RenderHandle {
    shutdown: Arc<AtomicBool>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl RenderHandle {
    /// Signals the thread and waits for it, so MODE(0) is out before we return (R5).
    pub fn shutdown(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }

    /// Whether the thread has been asked to stop.
    pub fn is_shutting_down(&self) -> bool {
        self.shutdown.load(Ordering::SeqCst)
    }

    /// Whether the render thread is still running.
    ///
    /// `panic = "abort"` is deliberately not set, so a panic in the render thread
    /// leaves the rest of the process alive: the socket stays bound and the lock
    /// stays held, and no replacement daemon can start while a frozen one holds
    /// them. The daemon polls this so it can exit instead (C4).
    pub fn is_running(&self) -> bool {
        self.join.as_ref().is_some_and(|join| !join.is_finished())
    }
}

impl Drop for RenderHandle {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Starts the render thread, sharing the caller's shutdown flag (the signal flag
/// in the daemon binary).
pub fn spawn<S>(render: RenderThread<S>, shutdown: Arc<AtomicBool>) -> std::io::Result<RenderHandle>
where
    S: DeviceSource + Send + 'static,
    S::Transport: Send,
{
    let thread_shutdown = Arc::clone(&shutdown);
    let join = std::thread::Builder::new()
        .name("gem80-rgb-render".to_string())
        .spawn(move || render.run(&thread_shutdown))?;
    Ok(RenderHandle {
        shutdown,
        join: Some(join),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};
    use std::time::Duration;

    use crate::compositor::Color;
    use crate::device::protocol::{
        HOSTRGB_CMD, HOSTRGB_SUB_HEARTBEAT, HOSTRGB_SUB_MODE, HOSTRGB_SUB_PROBE, HOSTRGB_SUB_SET,
        PACKETS_PER_FULL_FRAME, PAYLOAD_SIZE,
    };
    use crate::device::FakeTransport;
    use crate::server::{boundary_channel, BoundaryCall, BoundaryRequest, BoundarySender};
    use crate::sync::MutexExt;
    use crate::wire::{CompositeZIndex, ConnectionId};

    /// Firmware plus the observations a test wants: what was written, and whether a
    /// packet should fail.
    #[derive(Debug)]
    struct FakeDevice {
        firmware: FakeTransport,
        written: Vec<[u8; PAYLOAD_SIZE]>,
        present: bool,
        /// Index into the SET packets of the current frame that fails, if any.
        fail_set_at: Option<usize>,
        sets_since_frame: usize,
        /// Index of the SET packet after which a queued call is injected, if any.
        inject_at_set: Option<usize>,
        /// The call injected mid-repaint, sent once.
        inject: Option<(
            BoundarySender,
            std::sync::mpsc::Sender<crate::server::BoundaryResponse>,
        )>,
        /// Subcommand whose answers are lost after the firmware has applied them.
        swallow_answers_for_sub: Option<u8>,
        /// Index of the SET packet after which a connection cleanup is injected.
        inject_cleanup_at_set: Option<usize>,
        /// The cleanup injected mid-repaint, sent once.
        inject_cleanup: Option<(BoundarySender, ConnectionId)>,
        /// Wall time each write costs, so a watcher thread can observe ordering.
        write_delay: Duration,
    }

    impl FakeDevice {
        fn new() -> Self {
            Self {
                firmware: FakeTransport::new(),
                written: Vec::new(),
                present: true,
                fail_set_at: None,
                sets_since_frame: 0,
                inject_at_set: None,
                inject: None,
                swallow_answers_for_sub: None,
                inject_cleanup_at_set: None,
                inject_cleanup: None,
                write_delay: Duration::ZERO,
            }
        }

        fn subcommands(&self, sub: u8) -> usize {
            self.written.iter().filter(|p| p[1] == sub).count()
        }

        fn leds_written(&self) -> usize {
            self.written
                .iter()
                .filter(|p| p[1] == HOSTRGB_SUB_SET)
                .map(|p| p[3] as usize)
                .sum()
        }

        fn last(&self) -> Option<[u8; PAYLOAD_SIZE]> {
            self.written.last().copied()
        }

        fn clear_log(&mut self) {
            self.written.clear();
            self.sets_since_frame = 0;
        }
    }

    /// Shared handle so a test can inspect the firmware the render thread owns.
    #[derive(Debug, Clone)]
    struct SharedDevice(Arc<Mutex<FakeDevice>>);

    impl SharedDevice {
        fn new() -> Self {
            Self(Arc::new(Mutex::new(FakeDevice::new())))
        }

        fn lock(&self) -> MutexGuard<'_, FakeDevice> {
            self.0.lock_unpoisoned()
        }
    }

    impl Transport for SharedDevice {
        fn write_payload(&mut self, payload: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
            let (outcome, delay) = {
                let mut device = self.lock();
                device.written.push(*payload);
                let mut failed = false;
                if payload[1] == HOSTRGB_SUB_SET {
                    let index = device.sets_since_frame;
                    device.sets_since_frame += 1;
                    failed = device.fail_set_at == Some(index);
                    if device.inject_at_set == Some(index) {
                        if let Some((sender, reply)) = device.inject.take() {
                            let _ = sender.try_send_call(BoundaryCall::new(
                                ConnectionId(3),
                                BoundaryRequest::GetStatus {
                                    include_layers: false,
                                    include_composite_frame: false,
                                },
                                reply,
                            ));
                        }
                    }
                    if device.inject_cleanup_at_set == Some(index) {
                        if let Some((sender, connection)) = device.inject_cleanup.take() {
                            sender.send_connection_closed(connection);
                        }
                    }
                }
                let outcome = if failed {
                    Err(DeviceError::Io("simulated mid-frame packet failure".into()))
                } else {
                    let outcome = device.firmware.write_payload(payload);
                    // The firmware applied the command and then its answer was
                    // lost on the way back, which is a different hazard from a
                    // device that stopped listening.
                    if device.swallow_answers_for_sub == Some(payload[1]) {
                        device.firmware.rx_queue.pop_back();
                    }
                    outcome
                };
                (outcome, device.write_delay)
            };
            if !delay.is_zero() {
                std::thread::sleep(delay);
            }
            outcome
        }

        fn read_payload_timeout(
            &mut self,
            timeout_ms: u32,
        ) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
            self.lock().firmware.read_payload_timeout(timeout_ms)
        }
    }

    /// Hands out clones of one shared fake device, gated on `present`.
    struct FakeSource {
        device: SharedDevice,
    }

    impl FakeSource {
        fn new(device: SharedDevice) -> Self {
            Self { device }
        }
    }

    impl DeviceSource for FakeSource {
        type Transport = SharedDevice;

        fn is_present(&mut self) -> bool {
            self.device.lock().present
        }

        fn open(&mut self) -> Result<Option<Self::Transport>, DeviceError> {
            if self.device.lock().present {
                Ok(Some(self.device.clone()))
            } else {
                Ok(None)
            }
        }
    }

    struct Harness {
        render: RenderThread<FakeSource>,
        device: SharedDevice,
        sender: BoundarySender,
        now: Instant,
    }

    impl Harness {
        fn new() -> Self {
            Self::with_base(Color::rgb(1, 2, 3))
        }

        fn with_base(base: Color) -> Self {
            let device = SharedDevice::new();
            let (sender, receiver) = boundary_channel(16);
            let render = RenderThread::new(
                Compositor::with_base_color(base),
                receiver,
                FakeSource::new(device.clone()),
            );
            // Host and firmware start from one instant so every later advance moves
            // both by the same amount (H2).
            let now = Instant::now();
            device.lock().firmware.simulated_now = Some(now);
            Self {
                render,
                device,
                sender,
                now,
            }
        }

        /// Runs one tick and moves both clocks one tick period on.
        ///
        /// The firmware's simulated clock has to move with the host's: a fake that
        /// froze the device's notion of time while ticks accumulated would never
        /// let a deadline pass, and the watchdog paths it is supposed to exercise
        /// would go untested (H2).
        fn tick(&mut self) {
            self.render.tick_at(self.now);
            self.advance(self.render.timing().tick_period);
        }

        fn advance(&mut self, by: Duration) {
            self.now += by;
            self.device.lock().firmware.advance_time(by);
        }

        /// Moves both clocks past the firmware's armed deadline, so the next
        /// heartbeat is late and the firmware takes the regions back.
        fn advance_past_the_firmware_deadline(&mut self) {
            let deadline = self.render.timing().deadline;
            self.advance(deadline + Duration::from_millis(50));
        }

        /// Drives the machine to `DirectAll` with the base frame committed.
        fn settle(&mut self) {
            self.tick();
            assert_eq!(self.render.state(), DeviceStateKind::DirectAll);
        }
    }

    fn call(
        sender: &BoundarySender,
        connection: ConnectionId,
        request: BoundaryRequest,
    ) -> std::sync::mpsc::Receiver<crate::server::BoundaryResponse> {
        let (reply, rx) = std::sync::mpsc::channel();
        sender
            .try_send_call(BoundaryCall::new(connection, request, reply))
            .expect("boundary must accept the call");
        rx
    }

    /// Test scenario: 장치 없음 → 등장 → 프로브 → 진입 → 전체 프레임 전송. Covers AE5.
    #[test]
    fn test_absent_to_direct_all_sends_a_full_frame() {
        let mut h = Harness::with_base(Color::rgb(9, 8, 7));
        assert_eq!(h.render.state(), DeviceStateKind::Absent);

        h.tick();

        assert_eq!(h.render.state(), DeviceStateKind::DirectAll);
        let device = h.device.lock();
        assert_eq!(device.subcommands(HOSTRGB_SUB_PROBE), 1);
        assert_eq!(device.subcommands(HOSTRGB_SUB_MODE), 1);
        assert_eq!(device.subcommands(HOSTRGB_SUB_SET), PACKETS_PER_FULL_FRAME);
        assert_eq!(device.leds_written(), HOSTRGB_LED_COUNT);
        assert_eq!(device.firmware.led_buffer[0], (9, 8, 7));
        assert_eq!(device.firmware.led_buffer[HOSTRGB_LED_COUNT - 1], (9, 8, 7));
        assert_eq!(device.firmware.regions, HOSTRGB_REGION_ALL);
    }

    /// Test scenario: 키보드를 뽑았다 꽂으면 클라이언트가 아무것도 하지 않은 채 조명이
    /// 현재 합성 결과로 복귀한다. Covers AE5.
    #[test]
    fn test_device_leaving_and_returning_restores_the_current_composite() {
        let mut h = Harness::with_base(Color::rgb(2, 2, 2));
        h.settle();

        // A client paints one LED while the keyboard is still attached.
        let rx = call(
            &h.sender,
            ConnectionId(1),
            BoundaryRequest::RegisterLayer {
                name: "status".to_string(),
                z_order: CompositeZIndex(1),
                lifetime: None,
            },
        );
        h.tick();
        let layer = match rx.try_recv().expect("register must answer") {
            crate::server::BoundaryResponse::LayerRegistered(id) => id,
            other => panic!("unexpected response: {other:?}"),
        };
        let _rx = call(
            &h.sender,
            ConnectionId(1),
            BoundaryRequest::UpdateLayer {
                layer,
                set_pixels: vec![(7, Color::rgb(200, 100, 50))],
                retract_leds: vec![],
            },
        );
        h.tick();

        // The keyboard goes away mid-flight: the node stops answering.
        {
            let mut device = h.device.lock();
            device.present = false;
            device.firmware.drop_responses = true;
        }
        // Past the heartbeat period, so the tick actually reaches for the device.
        h.advance(h.render.timing().heartbeat_interval);
        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Absent);
        assert!(!h.render.compositor().is_mirror_valid());

        // Ticks keep running with no device, and the client does nothing at all.
        for _ in 0..3 {
            h.tick();
        }
        assert_eq!(h.render.compositor().layer_count(), 1);

        // The keyboard comes back.
        {
            let mut device = h.device.lock();
            device.present = true;
            device.firmware.drop_responses = false;
            device.firmware.led_buffer = [(0, 0, 0); HOSTRGB_LED_COUNT];
            device.clear_log();
        }
        h.advance(Duration::from_millis(2500));
        h.tick();

        assert_eq!(h.render.state(), DeviceStateKind::DirectAll);
        let device = h.device.lock();
        assert_eq!(
            device.leds_written(),
            HOSTRGB_LED_COUNT,
            "re-entry repaints all 101 LEDs (KTD3)"
        );
        assert_eq!(device.firmware.led_buffer[7], (200, 100, 50));
        assert_eq!(device.firmware.led_buffer[0], (2, 2, 2));
    }

    /// Test scenario: 재진입은 항상 `REGION_ALL` 마스크를 쓴다 (KTD2).
    #[test]
    fn test_entry_and_reentry_always_request_region_all() {
        let mut h = Harness::new();
        h.settle();
        h.advance_past_the_firmware_deadline();
        h.tick(); // heartbeat is rejected, re-entry follows
        h.tick();

        let device = h.device.lock();
        let modes: Vec<_> = device
            .written
            .iter()
            .filter(|p| p[1] == HOSTRGB_SUB_MODE)
            .collect();
        assert_eq!(modes.len(), 2);
        for mode in modes {
            assert_eq!(mode[0], HOSTRGB_CMD);
            assert_eq!(mode[2], HOSTRGB_REGION_ALL);
        }
    }

    /// Test scenario: 하트비트 거절 → 재진입 → 101개 LED 재전송. Covers AE3.
    #[test]
    fn test_rejected_heartbeat_reenters_and_resends_all_101_leds() {
        let mut h = Harness::new();
        h.settle();
        h.device.lock().clear_log();

        // Past the firmware deadline: the next heartbeat is rejected and the
        // firmware takes the regions back.
        h.advance_past_the_firmware_deadline();
        h.tick();

        assert_eq!(h.render.state(), DeviceStateKind::DirectAll);
        let device = h.device.lock();
        assert_eq!(device.subcommands(HOSTRGB_SUB_HEARTBEAT), 1);
        assert_eq!(device.subcommands(HOSTRGB_SUB_MODE), 1);
        assert_eq!(
            device.leds_written(),
            HOSTRGB_LED_COUNT,
            "re-entry must resend all 101 LEDs, not a zero-LED diff"
        );
        assert_eq!(h.render.stats().heartbeat_rejections, 1);
    }

    /// Test scenario: 재진입 없이 정상 tick이 이어질 때는 바뀐 LED만 전송된다. Covers AE8.
    #[test]
    fn test_steady_tick_writes_only_changed_leds() {
        let mut h = Harness::new();
        h.settle();
        h.device.lock().clear_log();

        // An unchanged composite writes nothing at all.
        h.tick();
        assert_eq!(h.device.lock().subcommands(HOSTRGB_SUB_SET), 0);

        let rx = call(
            &h.sender,
            ConnectionId(1),
            BoundaryRequest::RegisterLayer {
                name: "status".to_string(),
                z_order: CompositeZIndex(10),
                lifetime: None,
            },
        );
        h.tick();
        let layer = match rx.try_recv().expect("register must answer") {
            crate::server::BoundaryResponse::LayerRegistered(id) => id,
            other => panic!("unexpected response: {other:?}"),
        };

        h.device.lock().clear_log();
        let _rx = call(
            &h.sender,
            ConnectionId(1),
            BoundaryRequest::UpdateLayer {
                layer,
                set_pixels: vec![(42, Color::rgb(255, 0, 0))],
                retract_leds: vec![],
            },
        );
        h.tick();

        let device = h.device.lock();
        assert_eq!(device.subcommands(HOSTRGB_SUB_SET), 1);
        assert_eq!(device.leds_written(), 1);
        assert_eq!(device.firmware.led_buffer[42], (255, 0, 0));
    }

    /// Test scenario: 프레임 중간 패킷이 실패하면 다음 성공 주기에 101개가 전송된다. Covers AE13.
    #[test]
    fn test_mid_frame_failure_makes_the_next_successful_cycle_full() {
        let mut h = Harness::new();
        {
            let mut device = h.device.lock();
            device.fail_set_at = Some(3);
        }

        h.tick();
        assert_eq!(
            h.render.state(),
            DeviceStateKind::Absent,
            "a failed packet drops the state and invalidates the mirror (R23)"
        );
        assert!(!h.render.compositor().is_mirror_valid());

        {
            let mut device = h.device.lock();
            device.fail_set_at = None;
            device.clear_log();
        }
        // The write failure armed a retry delay, so the reopen waits for it (B4).
        h.advance(h.render.timing().probe_backoff_initial + Duration::from_millis(10));
        h.tick();

        let device = h.device.lock();
        assert_eq!(device.subcommands(HOSTRGB_SUB_SET), PACKETS_PER_FULL_FRAME);
        assert_eq!(device.leds_written(), HOSTRGB_LED_COUNT);
    }

    /// Test scenario: 쓰기가 계속 실패해도 tick마다 재개방·재프로브·재진입을 반복하지
    /// 않고 간격을 늘려 간다 (B4).
    #[test]
    fn test_persistent_write_failure_backs_off_instead_of_hammering() {
        let mut h = Harness::new();
        h.device.lock().fail_set_at = Some(0);

        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Absent);
        let probes_after_first_failure = h.render.stats().probes_sent;
        assert_eq!(probes_after_first_failure, 1);

        // Four more tick periods stay inside the first backoff window.
        for _ in 0..4 {
            h.tick();
        }
        assert_eq!(
            h.render.stats().probes_sent,
            probes_after_first_failure,
            "the backoff must hold the reopen back, not one reopen per tick"
        );

        h.advance(h.render.timing().probe_backoff_initial);
        h.tick();
        assert_eq!(
            h.render.stats().probes_sent,
            probes_after_first_failure + 1,
            "once the window passes, the daemon tries again"
        );
    }

    /// Test scenario: MODE 응답이 유실되어 호스트가 `Absent`로 내려가도, 장치에는
    /// `MODE(0)` 정리가 나가 사용자의 저장된 효과가 돌아온다 (B3, R5).
    #[test]
    fn test_a_lost_mode_answer_still_sends_the_mode_zero_cleanup() {
        let mut h = Harness::new();
        h.settle();

        // Only MODE answers are lost from here on. The firmware still applies them,
        // which is the hazard: it holds direct mode and the host cannot tell.
        {
            let mut device = h.device.lock();
            device.clear_log();
            device.swallow_answers_for_sub = Some(HOSTRGB_SUB_MODE);
        }
        // A late heartbeat is answered and rejected, so the machine reaches
        // `Entering`; the MODE it then sends is applied and goes unanswered.
        h.advance_past_the_firmware_deadline();
        h.tick();

        assert_eq!(
            h.render.state(),
            DeviceStateKind::Absent,
            "a lost MODE answer reads as an I/O failure"
        );
        let device = h.device.lock();
        let modes: Vec<_> = device
            .written
            .iter()
            .filter(|p| p[1] == HOSTRGB_SUB_MODE)
            .collect();
        assert_eq!(
            modes.last().map(|m| m[2]),
            Some(0),
            "the last MODE on the wire must be the MODE(0) cleanup, got {modes:?}"
        );
        assert_eq!(
            device.firmware.regions, 0,
            "the device must not be left holding direct mode"
        );
    }

    /// Test scenario: 개정 2가 아닌 프로브 응답에서는 모드 명령이 한 번도 나가지 않는다. Covers AE14.
    #[test]
    fn test_incompatible_firmware_never_sends_mode() {
        let mut h = Harness::new();
        h.device.lock().firmware.protocol_revision = 1;

        for _ in 0..5 {
            h.tick();
        }

        assert_eq!(h.render.state(), DeviceStateKind::Incompatible);
        let device = h.device.lock();
        assert_eq!(device.subcommands(HOSTRGB_SUB_MODE), 0);
        assert_eq!(device.subcommands(HOSTRGB_SUB_SET), 0);
    }

    /// Test scenario: 개정이 2라도 보고된 LED 기하가 다르면 direct mode에 들어가지 않는다.
    /// Covers G3.
    #[test]
    fn test_firmware_with_a_different_led_geometry_never_sends_mode() {
        let mut h = Harness::new();
        // Revision 2, but 96 LEDs: writing this device at the renderer's addresses
        // would paint the wrong LEDs.
        h.device.lock().firmware.reported_geometry = (96, 9, 89);

        for _ in 0..5 {
            h.tick();
        }

        assert_eq!(h.render.state(), DeviceStateKind::Incompatible);
        let device = h.device.lock();
        assert_eq!(device.subcommands(HOSTRGB_SUB_MODE), 0);
        assert_eq!(device.subcommands(HOSTRGB_SUB_SET), 0);
    }

    /// Test scenario: 호환되지 않는 상태에서 열거는 계속 돌고 프로브는 나가지 않는다 (KTD9).
    #[test]
    fn test_incompatible_state_keeps_enumerating_without_probing() {
        let mut h = Harness::new();
        h.device.lock().firmware.protocol_revision = 1;
        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Incompatible);

        let probes_after_verdict = h.render.stats().probes_sent;
        let enumerations_after_verdict = h.render.stats().enumerations;
        for _ in 0..10 {
            h.tick();
        }
        assert_eq!(
            h.render.stats().probes_sent,
            probes_after_verdict,
            "no probe may leave the Incompatible state"
        );
        assert!(
            h.render.stats().enumerations > enumerations_after_verdict,
            "enumeration keeps running while probing stops"
        );

        // The device leaving enumeration is the only way back to Absent.
        h.device.lock().present = false;
        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Absent);
    }

    /// Test scenario: 응답이 없는 가짜 전송에서 `Absent`로 내려가고 tick이 계속 돈다. Covers AE4.
    #[test]
    fn test_silent_device_drops_to_absent_and_ticks_keep_running() {
        let mut h = Harness::new();
        h.device.lock().firmware.drop_responses = true;

        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Absent);
        assert_eq!(
            h.render.stats().probes_sent,
            1,
            "silence is a boot delay, not an incompatible verdict (R4, AE15)"
        );

        let ticks_before = h.render.stats().ticks;
        for _ in 0..5 {
            h.tick();
        }
        assert_eq!(h.render.stats().ticks, ticks_before + 5);
        assert_ne!(h.render.state(), DeviceStateKind::Incompatible);
    }

    /// Test scenario: 장치가 붙자마자 답하지 않으면 간격을 늘려가며 다시 묻고, 답하기
    /// 시작하면 정상 경로로 들어간다. Covers AE15.
    #[test]
    fn test_silent_device_is_retried_with_growing_backoff_then_recovers() {
        let mut h = Harness::new();
        h.device.lock().firmware.drop_responses = true;
        h.tick();
        assert_eq!(h.render.stats().probes_sent, 1);

        // Inside the backoff window no probe goes out.
        h.tick();
        assert_eq!(h.render.stats().probes_sent, 1);

        h.advance(Duration::from_millis(120));
        h.tick();
        assert_eq!(h.render.stats().probes_sent, 2);

        // The second failure widens the window: 100 ms is no longer enough.
        h.advance(Duration::from_millis(120));
        h.tick();
        assert_eq!(h.render.stats().probes_sent, 2);

        h.advance(Duration::from_millis(120));
        h.device.lock().firmware.drop_responses = false;
        h.tick();
        assert_eq!(h.render.stats().probes_sent, 3);
        assert_eq!(h.render.state(), DeviceStateKind::DirectAll);
        assert_eq!(h.device.lock().leds_written(), HOSTRGB_LED_COUNT);
    }

    /// Test scenario: 장치가 없는 동안에도 tick이 돌고 수명 만료가 처리된다.
    #[test]
    fn test_ticks_and_lifetime_expiry_run_without_a_device() {
        let mut h = Harness::new();
        h.device.lock().present = false;

        let rx = call(
            &h.sender,
            ConnectionId(7),
            BoundaryRequest::RegisterLayer {
                name: "ephemeral".to_string(),
                z_order: CompositeZIndex(5),
                lifetime: Some(Duration::from_millis(40)),
            },
        );
        h.tick();
        assert!(matches!(
            rx.try_recv()
                .expect("register must answer with no device attached"),
            crate::server::BoundaryResponse::LayerRegistered(_)
        ));
        assert_eq!(h.render.state(), DeviceStateKind::Absent);
        assert_eq!(h.render.compositor().layer_count(), 1);

        h.tick();
        h.tick();
        h.tick();
        assert_eq!(
            h.render.compositor().layer_count(),
            0,
            "lifetime sweeps run on the tick, device or no device (R10)"
        );
    }

    /// Test scenario: 재도색 중에 도착한 상태 변경 호출은 그 재도색 안에서 적용되지 않고
    /// 다음 tick 경계에서 처리된다 (C1).
    ///
    /// Draining calls between packets would run arbitrary compositing inside the
    /// window `F_budget` is supposed to bound, and would change the composite while
    /// stale packets were still going out, so the hardware mirror would end up
    /// describing a frame the keyboard never received.
    #[test]
    fn test_calls_arriving_during_a_repaint_wait_for_the_tick_boundary() {
        let mut h = Harness::new();
        h.settle();
        h.device.lock().clear_log();

        // Force a full repaint on the next tick.
        h.render.compositor.invalidate_mirror();

        // The call arrives while the repaint is in flight: the fake device queues it
        // as the second packet goes out, and each write costs a millisecond so the
        // watcher can see where in the repaint the answer landed.
        let (reply, rx) = std::sync::mpsc::channel();
        {
            let mut device = h.device.lock();
            device.inject_at_set = Some(1);
            device.inject = Some((h.sender.clone(), reply));
            device.write_delay = Duration::from_millis(1);
        }

        let device = h.device.clone();
        let answered_after: Arc<Mutex<Option<usize>>> = Arc::new(Mutex::new(None));
        let recorder = Arc::clone(&answered_after);

        let watcher = std::thread::spawn(move || {
            let response = rx
                .recv_timeout(Duration::from_secs(5))
                .expect("the render thread must answer at the next tick");
            let packets = device.lock().subcommands(HOSTRGB_SUB_SET);
            *recorder.lock_unpoisoned() = Some(packets);
            response
        });

        h.tick();
        assert_eq!(
            h.device.lock().subcommands(HOSTRGB_SUB_SET),
            PACKETS_PER_FULL_FRAME,
            "the repaint must complete without the queued call interrupting it"
        );
        assert!(
            h.render.boundary.pending_calls() > 0,
            "the call must still be queued when the repaint ends"
        );

        // The next tick drains it.
        h.tick();
        let response = watcher.join().expect("watcher thread must finish");
        assert!(matches!(
            response,
            crate::server::BoundaryResponse::Status(_)
        ));

        let packets_at_answer = answered_after
            .lock_unpoisoned()
            .expect("the answer must have been observed");
        assert!(
            packets_at_answer >= PACKETS_PER_FULL_FRAME,
            "the call was applied inside the repaint ({packets_at_answer} packets in)"
        );
    }

    /// Test scenario: 재도색 중에 들어온 연결 정리는 패킷 사이에서 곧바로 처리된다
    /// (C1, R13).
    #[test]
    fn test_connection_cleanup_is_drained_between_packets() {
        let mut h = Harness::new();
        h.settle();

        // A client paints one LED, so its layer is visible in the composite.
        let rx = call(
            &h.sender,
            ConnectionId(3),
            BoundaryRequest::RegisterLayer {
                name: "doomed".to_string(),
                z_order: CompositeZIndex(1),
                lifetime: None,
            },
        );
        h.tick();
        let layer = match rx.try_recv().expect("register must answer") {
            crate::server::BoundaryResponse::LayerRegistered(id) => id,
            other => panic!("unexpected response: {other:?}"),
        };
        let _rx = call(
            &h.sender,
            ConnectionId(3),
            BoundaryRequest::UpdateLayer {
                layer,
                set_pixels: vec![(5, Color::rgb(9, 9, 9))],
                retract_leds: vec![],
            },
        );
        h.tick();
        assert_eq!(h.render.compositor().layer_count(), 1);

        // Force a full repaint, and let the connection die as its second packet
        // goes out.
        h.render.compositor.invalidate_mirror();
        {
            let mut device = h.device.lock();
            device.clear_log();
            device.inject_cleanup_at_set = Some(1);
            device.inject_cleanup = Some((h.sender.clone(), ConnectionId(3)));
        }

        h.tick();

        assert_eq!(
            h.render.compositor().layer_count(),
            0,
            "cleanup must not wait for the repaint to finish (R13)"
        );
        assert_eq!(
            h.device.lock().subcommands(HOSTRGB_SUB_SET),
            PACKETS_PER_FULL_FRAME,
            "the repaint in flight still completes"
        );
    }

    /// Test scenario: 정상 종료가 `MODE(0)`을 보낸 뒤 끝난다. Covers AE9.
    #[test]
    fn test_graceful_shutdown_sends_mode_zero() {
        let mut h = Harness::new();
        h.settle();
        h.device.lock().clear_log();

        h.render.shutdown_device();

        let device = h.device.lock();
        let last = device.last().expect("shutdown must write something");
        assert_eq!(last[1], HOSTRGB_SUB_MODE);
        assert_eq!(last[2], 0, "MODE(0) restores the stored effect (R5)");
        assert_eq!(device.firmware.regions, 0);
        assert_eq!(device.firmware.deadline_ms, 0);
    }

    /// A shutdown from a state that never held direct mode owes the firmware nothing.
    #[test]
    fn test_shutdown_without_direct_mode_writes_nothing() {
        let mut h = Harness::new();
        h.device.lock().present = false;
        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Absent);

        h.render.shutdown_device();
        assert!(h.device.lock().written.is_empty());
    }

    /// The running loop leaves direct mode when the shutdown flag is set (R5, AE9).
    #[test]
    fn test_run_loop_exits_through_mode_zero() {
        let device = SharedDevice::new();
        let (_sender, receiver) = boundary_channel(16);
        let render = RenderThread::new(
            Compositor::with_base_color(Color::rgb(4, 5, 6)),
            receiver,
            FakeSource::new(device.clone()),
        );
        let shutdown = Arc::new(AtomicBool::new(false));
        let mut handle = spawn(render, Arc::clone(&shutdown)).expect("render thread must start");

        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && device.lock().firmware.regions != HOSTRGB_REGION_ALL {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(device.lock().firmware.regions, HOSTRGB_REGION_ALL);

        handle.shutdown();

        let device = device.lock();
        assert_eq!(device.firmware.regions, 0);
        let last = device.last().expect("the loop must have written");
        assert_eq!(last[1], HOSTRGB_SUB_MODE);
        assert_eq!(last[2], 0);
    }

    /// Test scenario: 최악의 희소 갱신 패킷 수도 `F_budget` 안에 든다 (KTD12).
    #[test]
    fn test_worst_case_sparse_update_stays_inside_the_frame_budget() {
        let timing = Timing::DEFAULT;
        let mut frame = [Color::BLACK; GEM80_TOTAL_LEDS];
        // The worst shape: changed LEDs spread so no two share a nine-LED window.
        let diff: Vec<LedDiff> = (0..GEM80_TOTAL_LEDS)
            .step_by(HOSTRGB_LEDS_PER_PACKET)
            .map(|led_index| {
                frame[led_index] = Color::rgb(255, 255, 255);
                LedDiff {
                    led_index,
                    color: frame[led_index],
                }
            })
            .collect();
        assert_eq!(diff.len(), 12);

        let packets = plan_packets(&diff, &frame, timing.max_frame_packets);
        assert!(packets.len() <= timing.max_frame_packets);

        // Scattered every second LED: 51 changed LEDs, more round trips than a full
        // repaint if each got its own packet. The planner must not exceed the cap.
        let mut frame = [Color::BLACK; GEM80_TOTAL_LEDS];
        let diff: Vec<LedDiff> = (0..GEM80_TOTAL_LEDS)
            .step_by(2)
            .map(|led_index| {
                frame[led_index] = Color::rgb(1, 2, 3);
                LedDiff {
                    led_index,
                    color: frame[led_index],
                }
            })
            .collect();
        assert_eq!(diff.len(), 51);
        let packets = plan_packets(&diff, &frame, timing.max_frame_packets);
        assert!(
            packets.len() <= timing.max_frame_packets,
            "{} packets exceeds the {}-packet cap",
            packets.len(),
            timing.max_frame_packets
        );

        let worst = Duration::from_millis(
            (timing.round_trip_budget_ms as u64) * (timing.max_frame_packets as u64),
        );
        assert_eq!(worst, timing.frame_budget());
        assert!(worst + timing.tick_period + timing.jitter_allowance < timing.deadline / 2);
    }

    /// A diff that would need more packets than the cap allows becomes a repaint.
    ///
    /// The cap has to be crossed for the fallback to run at all. A diff that only
    /// reaches it takes the ordinary path, so a test built on one could not fail.
    #[test]
    fn test_pathologically_sparse_diff_falls_back_to_a_full_repaint() {
        let mut frame = [Color::BLACK; GEM80_TOTAL_LEDS];
        // One changed LED per nine-LED window: the most packets any diff over 101
        // LEDs can need, which is exactly the full-frame count.
        let diff: Vec<LedDiff> = (0..GEM80_TOTAL_LEDS)
            .step_by(HOSTRGB_LEDS_PER_PACKET)
            .map(|led_index| {
                frame[led_index] = Color::rgb(7, 7, 7);
                LedDiff {
                    led_index,
                    color: frame[led_index],
                }
            })
            .collect();
        assert_eq!(diff.len(), PACKETS_PER_FULL_FRAME);

        // At the cap, the sparse plan stands: 12 one-LED packets, not a repaint.
        let at_cap = plan_packets(&diff, &frame, PACKETS_PER_FULL_FRAME);
        assert_eq!(at_cap.len(), PACKETS_PER_FULL_FRAME);
        assert!(at_cap.iter().all(|p| p.colors.len() == 1));

        // Past it, the planner sends the whole frame instead.
        let over_cap = plan_packets(&diff, &frame, PACKETS_PER_FULL_FRAME - 1);
        assert_eq!(over_cap, full_frame_packets(&frame));
        let covered: usize = over_cap.iter().map(|p| p.colors.len()).sum();
        assert_eq!(covered, HOSTRGB_LED_COUNT);
    }

    /// The cap is read from the caller's timing, not from the default constants,
    /// so `F_budget` and the planner can never disagree (C2).
    #[test]
    fn test_the_packet_cap_comes_from_the_timing_in_force() {
        let timing = Timing {
            max_frame_packets: 2,
            // Fewer packets than the default leaves the invariant satisfied.
            ..Timing::DEFAULT
        };
        assert!(timing.invariant_holds());

        let device = SharedDevice::new();
        let (_sender, receiver) = boundary_channel(16);
        let mut render = RenderThread::with_timing(
            Compositor::with_base_color(Color::rgb(4, 4, 4)),
            receiver,
            FakeSource::new(device.clone()),
            timing,
        );
        render.tick();
        assert_eq!(render.state(), DeviceStateKind::DirectAll);
        device.lock().clear_log();

        // Three scattered LEDs would need three packets, one over this cap.
        render
            .compositor
            .set_base_pixels([
                (0, Color::rgb(1, 1, 1)),
                (40, Color::rgb(2, 2, 2)),
                (80, Color::rgb(3, 3, 3)),
            ])
            .expect("base pixels are in range");
        render.tick();

        assert_eq!(
            device.lock().subcommands(HOSTRGB_SUB_SET),
            PACKETS_PER_FULL_FRAME,
            "a diff over this instance's cap must fall back to a full repaint"
        );
    }

    /// Consecutive changed LEDs share one packet instead of one packet each.
    #[test]
    fn test_consecutive_changes_share_a_packet() {
        let mut frame = [Color::BLACK; GEM80_TOTAL_LEDS];
        let diff: Vec<LedDiff> = (10..15)
            .map(|led_index| {
                frame[led_index] = Color::rgb(3, 3, 3);
                LedDiff {
                    led_index,
                    color: frame[led_index],
                }
            })
            .collect();

        let packets = plan_packets(&diff, &frame, Timing::DEFAULT.max_frame_packets);
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0].start, 10);
        assert_eq!(packets[0].colors.len(), 5);
    }

    /// The status a client sees carries the render thread's current device state (R20).
    #[test]
    fn test_status_reports_the_incompatible_device_state() {
        let mut h = Harness::new();
        h.device.lock().firmware.protocol_revision = 1;
        h.tick();
        assert_eq!(h.render.state(), DeviceStateKind::Incompatible);

        let rx = call(
            &h.sender,
            ConnectionId(2),
            BoundaryRequest::GetStatus {
                include_layers: false,
                include_composite_frame: false,
            },
        );
        h.tick();
        match rx.try_recv().expect("status must answer") {
            crate::server::BoundaryResponse::Status(status) => assert_eq!(
                status.device_state,
                crate::wire::DeviceState::Incompatible as i32
            ),
            other => panic!("unexpected response: {other:?}"),
        }
    }
}
