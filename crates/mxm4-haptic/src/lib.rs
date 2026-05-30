//! Shared internals for the mxm4-haptic binary set:
//!   mxm4-haptic         thin one-shot client (spawned by Solaar rules)
//!   mxm4-hapticd        haptic daemon (sole owner of the hidraw device)
//!   mxm4-haptic-notify  desktop-notification -> haptic bridge
//!
//! The client and the notification watcher never touch the device: they
//! send a waveform name to the daemon over an AF_UNIX socket, and the
//! daemon does discovery, debounce, queueing and paced playback. This
//! keeps a single owner of the HID++ session and removes the on-disk
//! cache the old single-shot binary needed.
//!
//! Linux + macOS. Device access goes through the `hidapi` crate (daemon
//! only); the AF_UNIX socket works on both platforms. See crates/README.md.

use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// (name, id) for every HAPTIC waveform. IDs from
/// logitech_receiver.hidpp20_constants.HapticWaveForms. Note WHISPER
/// COLLISION = 27, not 15 — the firmware enum has a gap between MAD (11)
/// and WHISPER COLLISION (27).
pub const WAVEFORMS: &[(&str, u8)] = &[
    ("SHARP STATE CHANGE", 0),
    ("DAMP STATE CHANGE", 1),
    ("SHARP COLLISION", 2),
    ("DAMP COLLISION", 3),
    ("SUBTLE COLLISION", 4),
    ("HAPPY ALERT", 5),
    ("ANGRY ALERT", 6),
    ("COMPLETED", 7),
    ("SQUARE", 8),
    ("WAVE", 9),
    ("FIREWORK", 10),
    ("MAD", 11),
    ("KNOCK", 12),
    ("JINGLE", 13),
    ("RINGING", 14),
    ("WHISPER COLLISION", 27),
];

/// Resolve a (case-insensitive) waveform name to its firmware id.
pub fn waveform_id(name: &str) -> Option<u8> {
    let upper = name.to_uppercase();
    WAVEFORMS.iter().find(|(n, _)| *n == upper).map(|(_, id)| *id)
}

/// All waveform names, for usage/error output.
pub fn waveform_names() -> Vec<&'static str> {
    WAVEFORMS.iter().map(|(n, _)| *n).collect()
}

/// AF_UNIX rendezvous between the clients and the daemon. Lives in the
/// per-user runtime dir so it is never reachable outside this user session.
///
/// Linux: `$XDG_RUNTIME_DIR` (a 0700 tmpfs the kernel reaps on logout).
/// macOS: there is no `XDG_RUNTIME_DIR`; fall back to `$TMPDIR`, which
/// launchd sets per-user to the private 0700 `DARWIN_USER_TEMP_DIR`
/// (`/var/folders/.../T/`) — the closest equivalent. Last-resort `/tmp`
/// keeps the client/daemon able to rendezvous on an unusual session.
pub fn socket_path() -> Option<String> {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .or_else(|| std::env::var("TMPDIR").ok().filter(|d| !d.is_empty()))
        .unwrap_or_else(|| "/tmp".to_string());
    let dir = dir.trim_end_matches('/');
    Some(format!("{dir}/mxm4-haptic.sock"))
}

/// Connect to the daemon and hand it one waveform name. Fire-and-return:
/// the daemon owns debounce/queue/pacing, so the caller must not block on
/// playback. A missing socket or refused connection is a normal error
/// (daemon not running) and is surfaced to the caller, not swallowed.
pub fn send_command(name: &str) -> io::Result<()> {
    let path = socket_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR unset"))?;
    let mut stream = UnixStream::connect(&path)?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(name.as_bytes())?;
    stream.write_all(b"\n")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Daemon-only device internals (used by mxm4-hapticd). Public so the binary
// crate can reuse them; unused by the client/watcher binaries.
// ---------------------------------------------------------------------------

// Logitech Bolt receiver USB IDs (the MX Master 4 pairs through it).
pub const BOLT_VID: u16 = 0x046D;
pub const BOLT_PID: u16 = 0xC548;
// The receiver's HID++ control endpoint, used to pick the right node out of
// hidapi's enumeration (a receiver exposes several HID interfaces). On Linux
// it is USB interface 2 (the old code's `input2`); only this interface
// accepts HID++ reports cleanly (others EPIPE or silently discard). macOS
// reports interface_number as -1, so there it is matched by the Logitech
// vendor usage page 0xFF00 instead. The daemon accepts either.
pub const HIDPP_INTERFACE: i32 = 2;
pub const HIDPP_USAGE_PAGE: u16 = 0xFF00;

/// HID++ Long report (0x11) that plays one waveform: feature 0x19B0,
/// function 4 (PlayHapticWaveForm), sw_id 0 = fire-and-forget (sw_id 0 in
/// the low nibble of byte[3] still triggers playback; PLAY simply never
/// waits for the reply — no ack wait, ~1-2 ms). Verified: Solaar
/// settings_templates PlayHapticWaveForm write_fnid = 0x40 (func 4).
pub fn build_play_packet(dev_idx: u8, haptic_idx: u8, wf_id: u8) -> [u8; 20] {
    let mut pkt = [0u8; 20];
    pkt[0] = 0x11;
    pkt[1] = dev_idx;
    pkt[2] = haptic_idx;
    pkt[3] = 0x40;
    pkt[4] = wf_id;
    pkt
}

// ---------------------------------------------------------------------------
// HID++ discovery wire format (daemon only). Byte layouts verified against
// libratbag (hidpp20.c/hidpp10.c) and Solaar (base.py/receiver.py); see the
// daemon source for citations. The MX Master 4 is identified at runtime by
// being the receiver slot whose Root.GetFeature(0x19B0) returns a feature
// index instead of ERR_INVALID_FEATURE_INDEX — no model id, no cache.
// ---------------------------------------------------------------------------

pub const HIDPP_SHORT_REPORT_ID: u8 = 0x10;
pub const HIDPP_LONG_REPORT_ID: u8 = 0x11;
pub const HIDPP10_ERROR_SUB_ID: u8 = 0x8F;
pub const HIDPP20_ERROR_SUB_ID: u8 = 0xFF;
/// Feature id of HAPTIC (0x19B0), split for the two request bytes.
pub const HAPTIC_FEATURE_HI: u8 = 0x19;
pub const HAPTIC_FEATURE_LO: u8 = 0xB0;
/// Our request software id. Must be nonzero (so the device replies) and
/// not 0x0B (Solaar's fixed sw_id) so our replies don't collide with
/// Solaar's request/response matching on the shared hidraw.
pub const SW_ID: u8 = 0x0E;

/// Root.GetFeature(featureId): report 0x10, dev_idx, sub_id 0x00 (Root),
/// func 0 | sw_id in byte[3], feature id hi/lo. 7-byte short report.
pub fn build_get_feature(dev_idx: u8, feat_hi: u8, feat_lo: u8, sw_id: u8) -> [u8; 7] {
    [0x10, dev_idx, 0x00, sw_id & 0x0F, feat_hi, feat_lo, 0x00]
}

/// Receiver setRegister(reg, p0, p1, p2): report 0x10, dev_idx 0xFF
/// (receiver), sub_id 0x80 (setRegister). 7-byte short report.
pub fn build_set_register(reg: u8, p0: u8, p1: u8, p2: u8) -> [u8; 7] {
    [0x10, 0xFF, 0x80, reg, p0, p1, p2]
}

/// Enable receiver device-connection (0x41) notifications:
/// register 0x00 = WIRELESS(0x000100) | SOFTWARE_PRESENT(0x000800).
pub const ENABLE_NOTIFICATIONS: [u8; 7] = [0x10, 0xFF, 0x80, 0x00, 0x00, 0x09, 0x00];
/// Force the receiver to re-emit a 0x41 for every connected device
/// (register 0x02 = 0x02). Used to seed the connected-slot set.
pub const REANNOUNCE_DEVICES: [u8; 7] = [0x10, 0xFF, 0x80, 0x02, 0x02, 0x00, 0x00];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootReply {
    /// Root.GetFeature succeeded; the feature is present at this index.
    FeatureIndex(u8),
    /// HID++ 2.0 error (e.g. 0x06 ERR_INVALID_FEATURE_INDEX = no HAPTIC).
    Hidpp20Error(u8),
    /// HID++ 1.0 error.
    Hidpp10Error(u8),
    /// Not a reply to our Root.GetFeature (other traffic / Solaar / events).
    NotForUs,
}

/// Classify a read report as a reply to our Root.GetFeature for `dev_idx`
/// / `sw_id`. Success: sub_id(byte[2])==0x00, func|sw_id(byte[3])==sw_id,
/// feature index at byte[4]. Error: sub_id 0xFF/0x8F, echoed feat idx
/// (byte[3])==0x00, echoed func|sw_id (byte[4])==sw_id, code at byte[5].
pub fn classify_root_reply(buf: &[u8], dev_idx: u8, sw_id: u8) -> RootReply {
    if buf.len() < 7 {
        return RootReply::NotForUs;
    }
    match buf[0] {
        HIDPP_SHORT_REPORT_ID => {}
        HIDPP_LONG_REPORT_ID if buf.len() >= 20 => {}
        _ => return RootReply::NotForUs,
    }
    if buf[1] != dev_idx {
        return RootReply::NotForUs;
    }
    let sw = sw_id & 0x0F;
    match buf[2] {
        0x00 if buf[3] == sw => RootReply::FeatureIndex(buf[4]),
        HIDPP20_ERROR_SUB_ID if buf[3] == 0x00 && buf[4] == sw => RootReply::Hidpp20Error(buf[5]),
        HIDPP10_ERROR_SUB_ID if buf[3] == 0x00 && buf[4] == sw => RootReply::Hidpp10Error(buf[5]),
        _ => RootReply::NotForUs,
    }
}

/// Parse a 0x41 device-connection notification:
/// [0]=0x10, [1]=dev_idx, [2]=0x41, [4] bit 0x40 set => link LOST.
/// Returns (dev_idx, link_established).
pub fn parse_connection_notification(buf: &[u8]) -> Option<(u8, bool)> {
    if buf.len() < 7 || buf[0] != HIDPP_SHORT_REPORT_ID || buf[2] != 0x41 {
        return None;
    }
    Some((buf[1], (buf[4] & 0x40) == 0))
}
