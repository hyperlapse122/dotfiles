//! Device state machine (Absent, Probing, Incompatible, Entering, DirectAll).
//!
//! The render thread owns this machine; no other thread enters it (KTD7). The five
//! states and their edges mirror the plan's High-Level Technical Design diagram
//! one for one. Every edge into `Entering` invalidates the hardware mirror (KTD3),
//! and the only way out of `Incompatible` is enumeration (KTD9).
//!
//! The timing constants here carry KTD12's invariant `F_budget + T + jitter < D/2`.
//! `Timing::invariant_holds` is checked by a test, so changing a constant to a value
//! that breaks the invariant turns the suite red instead of opening the repaint /
//! watchdog / repaint loop on real hardware.

use std::time::Duration;

use crate::device::protocol::PACKETS_PER_FULL_FRAME;
use crate::wire::DeviceState as WireDeviceState;

/// Composition tick period `T`.
pub const TICK_PERIOD: Duration = Duration::from_millis(20);

/// Firmware watchdog deadline `D` armed on every MODE and HEARTBEAT.
///
/// KTD12 needs `D/2` above `F_budget + T + jitter`, which is 340 ms here, so `D`
/// cannot go below 680 ms. It is not raised far past that either: `D` is also how
/// long the lighting stays frozen on the last host frame after the daemon dies.
pub const FIRMWARE_DEADLINE: Duration = Duration::from_millis(800);

/// Heartbeat period: half the firmware deadline (R3).
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_millis(400);

/// Per-command read timeout. Exceeding it is an I/O failure, not a longer wait:
/// the state drops to `Absent` and the mirror is invalidated (KTD7, KTD12).
///
/// The verified reference implementation, `firmware/nuphy-gem80-hostrgb/hostrgb-probe.py`,
/// waits a full second. A timeout tight enough to be crossed by ordinary scheduler
/// jitter is an expensive false alarm: it costs a node reopen, a reprobe, a
/// re-entry and a full repaint.
pub const COMMAND_READ_TIMEOUT_MS: u32 = 20;

/// Allowance for the write half of one request-response round trip.
pub const COMMAND_WRITE_ALLOWANCE_MS: u32 = 5;

/// Upper bound on one request-response round trip (KTD1).
pub const ROUND_TRIP_BUDGET_MS: u32 = COMMAND_READ_TIMEOUT_MS + COMMAND_WRITE_ALLOWANCE_MS;

/// Upper bound on packets in a single frame write. A sparse update that would need
/// more packets than a full repaint is sent as a full repaint instead, so the frame
/// budget covers the worst-case sparse update as well as the full one (KTD12).
pub const MAX_FRAME_PACKETS: usize = PACKETS_PER_FULL_FRAME;

/// Slack for scheduler jitter between ticks.
pub const TICK_JITTER_ALLOWANCE: Duration = Duration::from_millis(20);

/// First retry delay after a probe that timed out or failed I/O (R4, AE15).
pub const PROBE_BACKOFF_INITIAL: Duration = Duration::from_millis(100);

/// Ceiling the probe retry delay grows to (R4, AE15).
pub const PROBE_BACKOFF_MAX: Duration = Duration::from_millis(2000);

/// Timing constants the render thread runs on, bound by KTD12's invariant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timing {
    /// Composition tick period `T`.
    pub tick_period: Duration,
    /// Firmware watchdog deadline `D`.
    pub deadline: Duration,
    /// Heartbeat period.
    pub heartbeat_interval: Duration,
    /// Read timeout handed to every device command.
    pub command_timeout_ms: u32,
    /// Upper bound on one round trip, write half included.
    pub round_trip_budget_ms: u32,
    /// Upper bound on packets per frame write.
    pub max_frame_packets: usize,
    /// Slack for scheduler jitter.
    pub jitter_allowance: Duration,
    /// First probe retry delay.
    pub probe_backoff_initial: Duration,
    /// Probe retry delay ceiling.
    pub probe_backoff_max: Duration,
}

impl Timing {
    /// The constants this daemon ships with.
    pub const DEFAULT: Self = Self {
        tick_period: TICK_PERIOD,
        deadline: FIRMWARE_DEADLINE,
        heartbeat_interval: HEARTBEAT_INTERVAL,
        command_timeout_ms: COMMAND_READ_TIMEOUT_MS,
        round_trip_budget_ms: ROUND_TRIP_BUDGET_MS,
        max_frame_packets: MAX_FRAME_PACKETS,
        jitter_allowance: TICK_JITTER_ALLOWANCE,
        probe_backoff_initial: PROBE_BACKOFF_INITIAL,
        probe_backoff_max: PROBE_BACKOFF_MAX,
    };

    /// Worst-case wall time of one frame write, `F_budget` in KTD12.
    pub const fn frame_budget(&self) -> Duration {
        Duration::from_millis((self.round_trip_budget_ms as u64) * (self.max_frame_packets as u64))
    }

    /// The firmware deadline in milliseconds, as the MODE and HEARTBEAT commands take it.
    pub const fn deadline_ms(&self) -> u32 {
        self.deadline.as_millis() as u32
    }

    /// KTD12: `F_budget + T + jitter < D/2`.
    pub fn invariant_holds(&self) -> bool {
        self.frame_budget() + self.tick_period + self.jitter_allowance < self.deadline / 2
    }
}

impl Default for Timing {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// Growing retry delay for a probe that timed out or failed I/O (R4, AE15).
///
/// A silent device may still be booting, so the daemon asks again — it just asks
/// less often each time, up to a ceiling. An explicit incompatible answer never
/// comes here: that one stops probing for good (KTD9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeBackoff {
    initial: Duration,
    max: Duration,
    current: Option<Duration>,
}

impl ProbeBackoff {
    /// Create a backoff with the given first delay and ceiling.
    pub const fn new(initial: Duration, max: Duration) -> Self {
        Self {
            initial,
            max,
            current: None,
        }
    }

    /// Create a backoff from a timing set.
    pub const fn from_timing(timing: &Timing) -> Self {
        Self::new(timing.probe_backoff_initial, timing.probe_backoff_max)
    }

    /// Return the next delay and grow it for the retry after that.
    pub fn advance(&mut self) -> Duration {
        let next = match self.current {
            None => self.initial,
            Some(current) => std::cmp::min(current.saturating_mul(2), self.max),
        };
        self.current = Some(next);
        next
    }

    /// The delay `advance` returned last, if any.
    pub fn current(&self) -> Option<Duration> {
        self.current
    }

    /// Forget the accumulated delay: the device answered.
    pub fn reset(&mut self) {
        self.current = None;
    }
}

impl Default for ProbeBackoff {
    fn default() -> Self {
        Self::from_timing(&Timing::DEFAULT)
    }
}

/// The five device states of the plan's state diagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceStateKind {
    /// No node is open. Enumeration runs every tick; composition keeps running (R2).
    Absent,
    /// A node is open and the firmware revision is being determined (R4).
    Probing,
    /// The firmware answered explicitly with a revision this daemon cannot drive.
    /// The node is closed and no further probe goes out until enumeration loses
    /// and refinds the device (KTD9).
    Incompatible,
    /// A MODE(REGION_ALL) request is owed. The mirror is already invalid here (KTD3).
    Entering,
    /// Direct mode is held over both regions; heartbeats and frame writes run (KTD2).
    DirectAll,
}

impl DeviceStateKind {
    /// The wire enum the CLI sees in a status response (R20).
    pub fn to_wire(self) -> WireDeviceState {
        match self {
            Self::Absent => WireDeviceState::Absent,
            Self::Probing => WireDeviceState::Probing,
            Self::Incompatible => WireDeviceState::Incompatible,
            Self::Entering => WireDeviceState::Entering,
            Self::DirectAll => WireDeviceState::DirectAll,
        }
    }

    /// Whether direct mode is currently held, so exiting it matters on shutdown (R5).
    pub fn holds_direct_mode(self) -> bool {
        matches!(self, Self::DirectAll)
    }

    /// Whether a probe may be sent from this state (KTD9).
    pub fn may_probe(self) -> bool {
        matches!(self, Self::Probing)
    }
}

/// What happened to the device, as observed by the render thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceEvent {
    /// Enumeration found the node and it was opened.
    Enumerated,
    /// Enumeration no longer lists the device (the only exit from `Incompatible`).
    VanishedFromEnumeration,
    /// The probe answered with revision 2.
    ProbeCompatible,
    /// The probe answered explicitly with a revision this daemon cannot drive.
    ProbeIncompatible,
    /// A command timed out or failed I/O.
    IoFailure,
    /// MODE(REGION_ALL) was accepted.
    ModeAccepted,
    /// The heartbeat was accepted; direct mode is still held.
    HeartbeatAccepted,
    /// The firmware rejected the heartbeat: the regions are gone (R3).
    HeartbeatRejected,
    /// A packet of a frame write failed (R23).
    WriteFailure,
}

/// The effects of one edge of the state diagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Transition {
    /// The state entered.
    pub next: DeviceStateKind,
    /// Whether the hardware mirror must be invalidated (KTD3).
    pub invalidate_mirror: bool,
    /// Whether the HID node must be closed.
    pub close_node: bool,
    /// Whether the probe backoff must be reset, the device having answered.
    pub reset_probe_backoff: bool,
    /// Whether the probe backoff must grow before the next attempt (R4, AE15).
    pub grow_probe_backoff: bool,
}

impl Transition {
    const fn to(next: DeviceStateKind) -> Self {
        Self {
            next,
            // Every edge into Entering invalidates the mirror (KTD3).
            invalidate_mirror: matches!(next, DeviceStateKind::Entering),
            close_node: false,
            reset_probe_backoff: false,
            grow_probe_backoff: false,
        }
    }

    const fn closing(mut self) -> Self {
        self.close_node = true;
        self
    }

    const fn invalidating(mut self) -> Self {
        self.invalidate_mirror = true;
        self
    }

    const fn resetting_backoff(mut self) -> Self {
        self.reset_probe_backoff = true;
        self
    }

    const fn growing_backoff(mut self) -> Self {
        self.grow_probe_backoff = true;
        self
    }
}

/// The state diagram, as one total function.
///
/// `None` means the event leaves the state unchanged.
pub fn transition(state: DeviceStateKind, event: DeviceEvent) -> Option<Transition> {
    use DeviceEvent as E;
    use DeviceStateKind as S;

    match (state, event) {
        (S::Absent, E::Enumerated) => Some(Transition::to(S::Probing)),

        (S::Probing, E::ProbeCompatible) => Some(Transition::to(S::Entering)),
        (S::Probing, E::ProbeIncompatible) => Some(Transition::to(S::Incompatible).closing()),
        (S::Probing, E::IoFailure) => Some(Transition::to(S::Absent).closing().growing_backoff()),

        (S::Incompatible, E::VanishedFromEnumeration) => {
            Some(Transition::to(S::Absent).resetting_backoff())
        }

        // An accepted MODE is the first edge that proves the whole path works:
        // enumeration, open, probe and entry all succeeded. A probe answer alone
        // does not, so the backoff is cleared here and not there (B4).
        (S::Entering, E::ModeAccepted) => Some(Transition::to(S::DirectAll).resetting_backoff()),
        (S::Entering, E::IoFailure) => Some(
            Transition::to(S::Absent)
                .closing()
                .invalidating()
                .growing_backoff(),
        ),

        (S::DirectAll, E::HeartbeatRejected) => Some(Transition::to(S::Entering)),
        // A persistent write or command failure must not reopen, reprobe and
        // re-enter every tick period: that hammers the hardware 50 times a second.
        (S::DirectAll, E::IoFailure) | (S::DirectAll, E::WriteFailure) => Some(
            Transition::to(S::Absent)
                .closing()
                .invalidating()
                .growing_backoff(),
        ),

        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test scenario: 선택된 tick 주기·하트비트 마감·재도색 예산 상수가 KTD12의 불변식
    /// `F_budget + T + jitter < D/2`를 만족한다.
    #[test]
    fn test_timing_constants_satisfy_ktd12_invariant() {
        let timing = Timing::DEFAULT;
        assert!(
            timing.invariant_holds(),
            "F_budget {:?} + T {:?} + jitter {:?} must stay under D/2 {:?}",
            timing.frame_budget(),
            timing.tick_period,
            timing.jitter_allowance,
            timing.deadline / 2
        );
        assert_eq!(timing.frame_budget(), Duration::from_millis(300));
        assert_eq!(timing.deadline / 2, Duration::from_millis(400));
    }

    /// Test scenario: 상수를 불변식이 깨지는 값으로 바꾸면 이 검사가 실패한다.
    #[test]
    fn test_invariant_check_rejects_a_budget_that_overruns_half_the_deadline() {
        let broken = Timing {
            // 30 round trips of 25 ms overruns D/2 = 400 ms on its own.
            max_frame_packets: 30,
            ..Timing::DEFAULT
        };
        assert!(!broken.invariant_holds());

        let also_broken = Timing {
            deadline: Duration::from_millis(600),
            ..Timing::DEFAULT
        };
        assert!(!also_broken.invariant_holds());
    }

    /// Heartbeats leave at D/2, and the worst-case frame write still lands before D.
    #[test]
    fn test_heartbeat_period_leaves_room_for_a_worst_case_frame_write() {
        let timing = Timing::DEFAULT;
        assert_eq!(timing.heartbeat_interval, timing.deadline / 2);
        let worst_arrival =
            timing.heartbeat_interval + timing.frame_budget() + timing.jitter_allowance;
        assert!(
            worst_arrival < timing.deadline,
            "worst heartbeat arrival {worst_arrival:?} must precede deadline {:?}",
            timing.deadline
        );
    }

    #[test]
    fn test_absent_enumerated_goes_probing() {
        let t = transition(DeviceStateKind::Absent, DeviceEvent::Enumerated).unwrap();
        assert_eq!(t.next, DeviceStateKind::Probing);
        assert!(!t.invalidate_mirror);
    }

    /// Covers AE14: an explicit non-revision-2 answer closes the node for good (KTD9).
    #[test]
    fn test_probe_incompatible_closes_node_and_stops_probing() {
        let t = transition(DeviceStateKind::Probing, DeviceEvent::ProbeIncompatible).unwrap();
        assert_eq!(t.next, DeviceStateKind::Incompatible);
        assert!(t.close_node);
        assert!(!t.next.may_probe());
    }

    /// Covers AE15: silence is a boot delay, not an incompatible verdict (R4).
    #[test]
    fn test_probe_io_failure_returns_to_absent_and_grows_backoff() {
        let t = transition(DeviceStateKind::Probing, DeviceEvent::IoFailure).unwrap();
        assert_eq!(t.next, DeviceStateKind::Absent);
        assert!(t.close_node);
        assert!(t.grow_probe_backoff);
    }

    /// KTD3: every edge into `Entering` invalidates the hardware mirror.
    #[test]
    fn test_every_edge_into_entering_invalidates_mirror() {
        for (state, event) in [
            (DeviceStateKind::Probing, DeviceEvent::ProbeCompatible),
            (DeviceStateKind::DirectAll, DeviceEvent::HeartbeatRejected),
        ] {
            let t = transition(state, event).unwrap();
            assert_eq!(t.next, DeviceStateKind::Entering);
            assert!(t.invalidate_mirror, "{state:?} + {event:?} must invalidate");
        }
    }

    /// R23: a failed frame packet drops to `Absent` with the mirror invalid, and
    /// backs off rather than reopening on the next tick (B4).
    #[test]
    fn test_write_failure_invalidates_mirror_and_drops_to_absent() {
        for event in [DeviceEvent::WriteFailure, DeviceEvent::IoFailure] {
            let t = transition(DeviceStateKind::DirectAll, event).unwrap();
            assert_eq!(t.next, DeviceStateKind::Absent);
            assert!(t.invalidate_mirror);
            assert!(t.close_node);
            assert!(
                t.grow_probe_backoff,
                "{event:?} out of DirectAll must back off before reopening"
            );
        }
    }

    /// The probe backoff clears on the edge proven to work end to end, not on a
    /// probe answer that may still be followed by a failed entry (B4).
    #[test]
    fn test_only_an_accepted_mode_clears_the_probe_backoff() {
        let probed = transition(DeviceStateKind::Probing, DeviceEvent::ProbeCompatible).unwrap();
        assert!(!probed.reset_probe_backoff);

        let entered = transition(DeviceStateKind::Entering, DeviceEvent::ModeAccepted).unwrap();
        assert_eq!(entered.next, DeviceStateKind::DirectAll);
        assert!(entered.reset_probe_backoff);
    }

    /// KTD9: only enumeration leaves `Incompatible`.
    #[test]
    fn test_incompatible_only_leaves_on_enumeration() {
        for event in [
            DeviceEvent::Enumerated,
            DeviceEvent::ProbeCompatible,
            DeviceEvent::ProbeIncompatible,
            DeviceEvent::IoFailure,
            DeviceEvent::ModeAccepted,
            DeviceEvent::HeartbeatAccepted,
            DeviceEvent::HeartbeatRejected,
            DeviceEvent::WriteFailure,
        ] {
            assert!(
                transition(DeviceStateKind::Incompatible, event).is_none(),
                "{event:?} must not move the machine out of Incompatible"
            );
        }
        let t = transition(
            DeviceStateKind::Incompatible,
            DeviceEvent::VanishedFromEnumeration,
        )
        .unwrap();
        assert_eq!(t.next, DeviceStateKind::Absent);
    }

    #[test]
    fn test_accepted_heartbeat_holds_direct_all() {
        assert!(transition(DeviceStateKind::DirectAll, DeviceEvent::HeartbeatAccepted).is_none());
    }

    #[test]
    fn test_state_kinds_map_onto_the_wire_enum() {
        assert_eq!(DeviceStateKind::Absent.to_wire(), WireDeviceState::Absent);
        assert_eq!(DeviceStateKind::Probing.to_wire(), WireDeviceState::Probing);
        assert_eq!(
            DeviceStateKind::Incompatible.to_wire(),
            WireDeviceState::Incompatible
        );
        assert_eq!(
            DeviceStateKind::Entering.to_wire(),
            WireDeviceState::Entering
        );
        assert_eq!(
            DeviceStateKind::DirectAll.to_wire(),
            WireDeviceState::DirectAll
        );
        assert!(DeviceStateKind::DirectAll.holds_direct_mode());
        assert!(!DeviceStateKind::Entering.holds_direct_mode());
    }

    #[test]
    fn test_probe_backoff_doubles_up_to_the_ceiling_and_resets() {
        let mut backoff = ProbeBackoff::default();
        assert_eq!(backoff.advance(), Duration::from_millis(100));
        assert_eq!(backoff.advance(), Duration::from_millis(200));
        assert_eq!(backoff.advance(), Duration::from_millis(400));
        for _ in 0..10 {
            backoff.advance();
        }
        assert_eq!(backoff.current(), Some(PROBE_BACKOFF_MAX));

        backoff.reset();
        assert_eq!(backoff.current(), None);
        assert_eq!(backoff.advance(), Duration::from_millis(100));
    }
}
