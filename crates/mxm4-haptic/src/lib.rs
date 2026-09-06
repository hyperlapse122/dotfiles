//! Shared internals for the logictl / mxm4-haptic binary suite:
//!   logictl             unified CLI (battery, haptic, status)
//!   logid               headless daemon (sole owner of device + SNI + IPC)
//!   mxm4-haptic         backward-compatible thin one-shot client
//!   mxm4-hapticd        backward-compatible daemon alias
//!   mxm4-haptic-notify  desktop-notification -> haptic bridge
//!
//! The clients and notification watcher never touch the device: they
//! communicate with the daemon over a local IPC endpoint ($XDG_RUNTIME_DIR/logid.sock
//! with symlink mxm4-haptic.sock). The daemon remains the single owner of the HID++ session.
//!
//! Linux + macOS. Device access goes through the `hidapi` crate (daemon only).

pub mod battery;
#[cfg(target_os = "linux")]
pub mod sni;

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// (name, id) for every HAPTIC waveform. IDs from
/// logitech_receiver.hidpp20_constants.HapticWaveForms. Note WHISPER
/// COLLISION = 27 (0x1B), not 15 — the firmware enum has a gap: ids run
/// 0x00..=0x0E contiguously, then 0x0F..=0x1A are unused and the last
/// waveform jumps to 0x1B. Do NOT "fix" this to a contiguous 0..15.
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
    WAVEFORMS
        .iter()
        .find(|(n, _)| *n == upper)
        .map(|(_, id)| *id)
}

/// All waveform names, for usage/error output.
pub fn waveform_names() -> Vec<&'static str> {
    WAVEFORMS.iter().map(|(n, _)| *n).collect()
}

/// Base runtime directory resolver ($XDG_RUNTIME_DIR -> $TMPDIR -> /tmp).
pub fn runtime_dir() -> Option<String> {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .or_else(|| std::env::var("TMPDIR").ok().filter(|d| !d.is_empty()))
        .unwrap_or_else(|| "/tmp".to_string());
    Some(dir.trim_end_matches('/').to_string())
}

/// Primary IPC socket path ($XDG_RUNTIME_DIR/logid.sock).
pub fn socket_path() -> Option<String> {
    runtime_dir().map(|d| format!("{d}/logid.sock"))
}

/// Legacy/compatibility IPC socket path ($XDG_RUNTIME_DIR/mxm4-haptic.sock).
pub fn legacy_socket_path() -> Option<String> {
    runtime_dir().map(|d| format!("{d}/mxm4-haptic.sock"))
}

/// Active socket path: prefers existing socket, falling back to primary.
pub fn active_socket_path() -> Option<String> {
    if let Some(p) = socket_path() {
        if std::path::Path::new(&p).exists() {
            return Some(p);
        }
    }
    if let Some(p) = legacy_socket_path() {
        if std::path::Path::new(&p).exists() {
            return Some(p);
        }
    }
    socket_path()
}

/// Connect to daemon and hand it one waveform name.
pub fn send_command(name: &str) -> io::Result<()> {
    let path = active_socket_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR unset"))?;
    let mut stream = UnixStream::connect(&path)?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(name.as_bytes())?;
    stream.write_all(b"\n")?;
    Ok(())
}

/// Overall daemon and device status structure.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonStatus {
    pub running: bool,
    pub device_connected: bool,
    pub device_slot: Option<u8>,
    pub haptic_index: Option<u8>,
    pub battery: Option<battery::BatteryInfo>,
}

/// Query current battery status from running daemon.
pub fn query_battery() -> io::Result<Option<battery::BatteryInfo>> {
    let path = active_socket_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR unset"))?;
    let mut stream = UnixStream::connect(&path)?;
    stream.set_read_timeout(Some(Duration::from_millis(1500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(b"BATTERY\n")?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed == "null" {
        return Ok(None);
    }
    let info: battery::BatteryInfo =
        serde_json::from_str(trimmed).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok(Some(info))
}

/// Query overall daemon status from running daemon.
pub fn query_status() -> io::Result<DaemonStatus> {
    let path = active_socket_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR unset"))?;
    let mut stream = UnixStream::connect(&path)?;
    stream.set_read_timeout(Some(Duration::from_millis(1500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(b"STATUS\n")?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let status: DaemonStatus = serde_json::from_str(line.trim())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    Ok(status)
}

// ---------------------------------------------------------------------------
// IPC server (daemon only). The daemon's AF_UNIX listener.
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum IpcMessage {
    Play(u8),
    QueryBattery(mpsc::Sender<Option<battery::BatteryInfo>>),
    QueryStatus(mpsc::Sender<DaemonStatus>),
}

mod ipc_server {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    pub struct IpcServer {
        listener: UnixListener,
        endpoint: String,
        legacy_endpoint: Option<String>,
    }

    impl IpcServer {
        pub fn bind() -> io::Result<Self> {
            let endpoint = super::socket_path().ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "no runtime dir for socket")
            })?;
            let legacy = super::legacy_socket_path();

            // Remove stale sockets
            let _ = std::fs::remove_file(&endpoint);
            if let Some(ref l) = legacy {
                let _ = std::fs::remove_file(l);
            }

            let listener = UnixListener::bind(&endpoint)?;
            std::fs::set_permissions(&endpoint, std::fs::Permissions::from_mode(0o600))?;

            // Create symlink for legacy socket compatibility
            if let Some(ref l) = legacy {
                let _ = std::os::unix::fs::symlink(&endpoint, l);
            }

            Ok(Self {
                listener,
                endpoint,
                legacy_endpoint: legacy,
            })
        }

        pub fn endpoint(&self) -> &str {
            &self.endpoint
        }

        pub fn accept(&self) -> io::Result<(UnixStream, String)> {
            let (stream, _) = self.listener.accept()?;
            let mut line = String::new();
            let mut reader = BufReader::new(&stream);
            let _ = reader.read_line(&mut line);
            Ok((stream, line.trim().to_string()))
        }

        /// Backward compatibility for mxm4-hapticd tests and simple loops.
        pub fn next_name(&self) -> io::Result<Option<String>> {
            let (_, line) = self.accept()?;
            if line.is_empty() {
                return Ok(None);
            }
            Ok(Some(line.to_uppercase()))
        }
    }

    impl Drop for IpcServer {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.endpoint);
            if let Some(ref l) = self.legacy_endpoint {
                let _ = std::fs::remove_file(l);
            }
        }
    }
}

pub use ipc_server::IpcServer;

// ---------------------------------------------------------------------------
// Daemon-only device internals (used by logid / mxm4-hapticd).
// ---------------------------------------------------------------------------

pub const BOLT_VID: u16 = 0x046D;
pub const BOLT_PID: u16 = 0xC548;
pub const HIDPP_INTERFACE: i32 = 2;
pub const HIDPP_USAGE_PAGE: u16 = 0xFF00;

pub fn build_play_packet(dev_idx: u8, haptic_idx: u8, wf_id: u8) -> [u8; 20] {
    let mut pkt = [0u8; 20];
    pkt[0] = 0x11;
    pkt[1] = dev_idx;
    pkt[2] = haptic_idx;
    pkt[3] = 0x40;
    pkt[4] = wf_id;
    pkt
}

pub const HIDPP_SHORT_REPORT_ID: u8 = 0x10;
pub const HIDPP_LONG_REPORT_ID: u8 = 0x11;
pub const HIDPP10_ERROR_SUB_ID: u8 = 0x8F;
pub const HIDPP20_ERROR_SUB_ID: u8 = 0xFF;
pub const HAPTIC_FEATURE_HI: u8 = 0x19;
pub const HAPTIC_FEATURE_LO: u8 = 0xB0;
pub const SW_ID: u8 = 0x0E;

pub fn build_get_feature(dev_idx: u8, feat_hi: u8, feat_lo: u8, sw_id: u8) -> [u8; 7] {
    [0x10, dev_idx, 0x00, sw_id & 0x0F, feat_hi, feat_lo, 0x00]
}

pub fn build_set_register(reg: u8, p0: u8, p1: u8, p2: u8) -> [u8; 7] {
    [0x10, 0xFF, 0x80, reg, p0, p1, p2]
}

pub const ENABLE_NOTIFICATIONS: [u8; 7] = [0x10, 0xFF, 0x80, 0x00, 0x00, 0x09, 0x00];
pub const REANNOUNCE_DEVICES: [u8; 7] = [0x10, 0xFF, 0x80, 0x02, 0x02, 0x00, 0x00];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootReply {
    FeatureIndex(u8),
    Hidpp20Error(u8),
    Hidpp10Error(u8),
    NotForUs,
}

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

pub fn parse_connection_notification(buf: &[u8]) -> Option<(u8, bool)> {
    if buf.len() < 7 || buf[0] != HIDPP_SHORT_REPORT_ID || buf[2] != 0x41 {
        return None;
    }
    Some((buf[1], (buf[4] & 0x40) == 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn waveform_table_has_16_entries() {
        assert_eq!(WAVEFORMS.len(), 16);
    }

    #[test]
    fn waveform_names_unique() {
        let mut names: Vec<&str> = WAVEFORMS.iter().map(|(n, _)| *n).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 16, "duplicate waveform names detected");
    }

    #[test]
    fn waveform_ids_unique() {
        let mut ids: Vec<u8> = WAVEFORMS.iter().map(|(_, id)| *id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), 16, "duplicate waveform ids detected");
    }

    #[test]
    fn waveform_id_exact_set() {
        let mut ids: Vec<u8> = WAVEFORMS.iter().map(|(_, id)| *id).collect();
        ids.sort_unstable();
        let mut expected: Vec<u8> = (0u8..=14).collect();
        expected.push(27);
        assert_eq!(ids, expected);
    }

    #[test]
    fn waveform_id_whisper_collision_is_27() {
        assert_eq!(waveform_id("WHISPER COLLISION"), Some(27));
    }

    #[test]
    fn waveform_id_ringing_is_14() {
        assert_eq!(waveform_id("RINGING"), Some(14));
    }

    #[test]
    fn waveform_id_case_insensitive() {
        assert_eq!(waveform_id("completed"), Some(7));
        assert_eq!(waveform_id("Sharp Collision"), Some(2));
    }

    #[test]
    fn waveform_id_unknown_returns_none() {
        assert_eq!(waveform_id("NOPE"), None);
        assert_eq!(waveform_id(""), None);
    }

    #[test]
    fn waveform_names_len_matches_table() {
        assert_eq!(waveform_names().len(), WAVEFORMS.len());
    }

    #[test]
    fn build_play_packet_layout() {
        let pkt = build_play_packet(1, 9, 27);
        assert_eq!(pkt.len(), 20);
        assert_eq!(pkt[0], 0x11);
        assert_eq!(pkt[1], 1);
        assert_eq!(pkt[2], 9);
        assert_eq!(pkt[3], 0x40);
        assert_eq!(pkt[4], 27);
        assert!(pkt[5..].iter().all(|&b| b == 0));
    }

    #[test]
    fn build_get_feature_layout() {
        let pkt = build_get_feature(2, 0x19, 0xB0, 0x0E);
        assert_eq!(pkt, [0x10, 2, 0x00, 0x0E, 0x19, 0xB0, 0x00]);
    }

    #[test]
    fn build_get_feature_sw_id_masked() {
        let pkt = build_get_feature(2, 0x19, 0xB0, 0xFE);
        assert_eq!(pkt[3], 0x0E);
    }

    #[test]
    fn build_set_register_matches_constants() {
        assert_eq!(
            build_set_register(0x00, 0x00, 0x09, 0x00),
            ENABLE_NOTIFICATIONS
        );
        assert_eq!(
            build_set_register(0x02, 0x02, 0x00, 0x00),
            REANNOUNCE_DEVICES
        );
    }

    #[test]
    fn classify_root_reply_success_short() {
        let buf = [0x10u8, 0x01, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(
            classify_root_reply(&buf, 0x01, 0x0E),
            RootReply::FeatureIndex(0x05)
        );
    }

    #[test]
    fn classify_root_reply_success_long() {
        let mut buf = [0u8; 20];
        buf[0] = 0x11;
        buf[1] = 0x02;
        buf[2] = 0x00;
        buf[3] = 0x0E;
        buf[4] = 0x07;
        assert_eq!(
            classify_root_reply(&buf, 0x02, 0x0E),
            RootReply::FeatureIndex(0x07)
        );
    }

    #[test]
    fn classify_root_reply_hidpp20_error() {
        let buf = [0x10u8, 0x01, 0xFF, 0x00, 0x0E, 0x06, 0x00];
        assert_eq!(
            classify_root_reply(&buf, 0x01, 0x0E),
            RootReply::Hidpp20Error(0x06)
        );
    }

    #[test]
    fn classify_root_reply_hidpp10_error() {
        let buf = [0x10u8, 0x01, 0x8F, 0x00, 0x0E, 0x09, 0x00];
        assert_eq!(
            classify_root_reply(&buf, 0x01, 0x0E),
            RootReply::Hidpp10Error(0x09)
        );
    }

    #[test]
    fn classify_root_reply_wrong_dev_idx() {
        let buf = [0x10u8, 0x03, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    #[test]
    fn classify_root_reply_wrong_sw_id() {
        let buf = [0x10u8, 0x01, 0x00, 0x0A, 0x05, 0x00, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    #[test]
    fn classify_root_reply_buf_too_short() {
        let buf = [0x10u8, 0x01, 0x00, 0x0E, 0x05, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    #[test]
    fn classify_root_reply_long_report_too_short() {
        let buf = [0x11u8, 0x01, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    #[test]
    fn classify_root_reply_unknown_report_id() {
        let buf = [0x20u8, 0x01, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    #[test]
    fn parse_connection_notification_link_established() {
        let buf = [0x10u8, 5, 0x41, 0, 0x00, 0, 0];
        assert_eq!(parse_connection_notification(&buf), Some((5, true)));
    }

    #[test]
    fn parse_connection_notification_link_lost() {
        let buf = [0x10u8, 5, 0x41, 0, 0x40, 0, 0];
        assert_eq!(parse_connection_notification(&buf), Some((5, false)));
    }

    #[test]
    fn parse_connection_notification_wrong_sub_id() {
        let buf = [0x10u8, 5, 0x42, 0, 0x00, 0, 0];
        assert_eq!(parse_connection_notification(&buf), None);
    }

    #[test]
    fn parse_connection_notification_wrong_report_id() {
        let buf = [0x11u8, 5, 0x41, 0, 0x00, 0, 0];
        assert_eq!(parse_connection_notification(&buf), None);
    }

    #[test]
    fn parse_connection_notification_too_short() {
        let buf = [0x10u8, 5, 0x41, 0, 0x00, 0];
        assert_eq!(parse_connection_notification(&buf), None);
    }

    #[test]
    fn socket_path_unix_env_resolution() {
        use std::env;
        let _guard = env_lock().lock().unwrap();

        let orig_xdg = env::var("XDG_RUNTIME_DIR").ok();
        let orig_tmp = env::var("TMPDIR").ok();

        unsafe {
            env::set_var("XDG_RUNTIME_DIR", "/run/user/1000/");
            env::remove_var("TMPDIR");
        }
        assert_eq!(socket_path(), Some("/run/user/1000/logid.sock".to_string()));
        assert_eq!(
            legacy_socket_path(),
            Some("/run/user/1000/mxm4-haptic.sock".to_string())
        );

        unsafe {
            env::remove_var("XDG_RUNTIME_DIR");
            env::set_var("TMPDIR", "/var/tmpx");
        }
        assert_eq!(socket_path(), Some("/var/tmpx/logid.sock".to_string()));
        assert_eq!(
            legacy_socket_path(),
            Some("/var/tmpx/mxm4-haptic.sock".to_string())
        );

        unsafe {
            env::remove_var("XDG_RUNTIME_DIR");
            env::remove_var("TMPDIR");
        }
        assert_eq!(socket_path(), Some("/tmp/logid.sock".to_string()));
        assert_eq!(
            legacy_socket_path(),
            Some("/tmp/mxm4-haptic.sock".to_string())
        );

        unsafe {
            match orig_xdg {
                Some(v) => env::set_var("XDG_RUNTIME_DIR", v),
                None => env::remove_var("XDG_RUNTIME_DIR"),
            }
            match orig_tmp {
                Some(v) => env::set_var("TMPDIR", v),
                None => env::remove_var("TMPDIR"),
            }
        }
    }

    #[test]
    fn ipc_server_socket_is_owner_only_and_symlinks_legacy() {
        use std::env;
        use std::os::unix::fs::PermissionsExt;
        let _guard = env_lock().lock().unwrap();

        let orig_xdg = env::var("XDG_RUNTIME_DIR").ok();
        let orig_tmp = env::var("TMPDIR").ok();
        let dir = env::temp_dir().join(format!("logid-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create temp runtime dir");

        unsafe {
            env::set_var("XDG_RUNTIME_DIR", &dir);
            env::remove_var("TMPDIR");
        }

        let server = IpcServer::bind().expect("bind ipc socket");
        let mode = std::fs::metadata(server.endpoint())
            .expect("socket metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);

        let legacy = legacy_socket_path().unwrap();
        assert!(std::path::Path::new(&legacy).exists());

        let endpoint = server.endpoint().to_string();
        drop(server);
        assert!(!std::path::Path::new(&endpoint).exists());
        assert!(!std::path::Path::new(&legacy).exists());
        let _ = std::fs::remove_dir(&dir);

        unsafe {
            match orig_xdg {
                Some(v) => env::set_var("XDG_RUNTIME_DIR", v),
                None => env::remove_var("XDG_RUNTIME_DIR"),
            }
            match orig_tmp {
                Some(v) => env::set_var("TMPDIR", v),
                None => env::remove_var("TMPDIR"),
            }
        }
    }
}
