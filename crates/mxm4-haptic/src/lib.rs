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
//! Linux + macOS + Windows. Device access goes through the `hidapi` crate
//! (daemon only). The client<->daemon rendezvous is an AF_UNIX socket on
//! Unix and a Win32 named pipe on Windows (std has no AF_UNIX there); both
//! are abstracted behind `socket_path()`, `send_command()`, and `IpcServer`.
//! See crates/README.md.

use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(unix)]
use std::time::Duration;

/// (name, id) for every HAPTIC waveform. IDs from
/// logitech_receiver.hidpp20_constants.HapticWaveForms. Note WHISPER
/// COLLISION = 27 (0x1B), not 15 — the firmware enum has a gap: ids run
/// 0x00..=0x0E contiguously, then 0x0F..=0x1A are unused and the last
/// waveform jumps to 0x1B. Do NOT "fix" this to a contiguous 0..15.
///
/// Feature 0x19B0 (HAPTIC) and its waveform set are NOT in Logitech's
/// public HID++ 2.0 docs (cpg-docs only specifies the generic packet /
/// IRoot.GetFeature mechanism); the catalogue below is community
/// reverse-engineered and cross-verified against four independent impls:
///
/// References (canonical source = Solaar):
/// - Solaar HapticWaveForms enum (1st source):
///   <https://github.com/pwr-Solaar/Solaar/blob/f68230b83d2ea83c222e1bdfc7f404777f78dc1b/lib/logitech_receiver/hidpp20_constants.py#L368-L385>
/// - Solaar HAPTIC = 0x19B0 + PlayHapticWaveForm setting (write_fnid 0x40,
///   probes feature_request(HAPTIC, 0x00) for supported waveforms):
///   <https://github.com/pwr-Solaar/Solaar/blob/f68230b83d2ea83c222e1bdfc7f404777f78dc1b/lib/logitech_receiver/settings_templates.py#L4411-L4432>
/// - JuhLabs/juhradial-mx Mx4HapticPattern (Rust, same enum):
///   <https://github.com/JuhLabs/juhradial-mx/blob/48939bae45fd074b209264f0cafd709844a4a996/daemon/src/hidpp/patterns.rs#L77-L166>
/// - olafnew/MasterMice raw HID++ haptic packets (func 0x02 = 0x2A,
///   func 0x04 = 0x4A play):
///   <https://github.com/olafnew/MasterMice/blob/878f294e64ea5c527997a238de4afc1a0b5650c/service/internal/hidpp/haptic.go#L106-L159>
///
/// Feature 0x19B0 functions (community-documented): 0x00 query supported
/// waveform bitmask, 0x02 enable/intensity, 0x04 play.
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

/// Windows named-pipe endpoint, shared byte-for-byte with the TS client
/// `@h82/mxm4-haptic` (packages/mxm4-haptic/src/index.ts). The two MUST
/// agree. Unlike the per-user POSIX runtime dir, this is the machine-global
/// `\\.\pipe` namespace; the server relies on the pipe's default ACL (which
/// grants the creating user full control) — see the crate README caveat.
#[cfg(windows)]
pub const WINDOWS_PIPE_PATH: &str = r"\\.\pipe\mxm4-haptic";

/// Rendezvous endpoint between the clients and the daemon.
///
/// Windows: a named pipe (`\\.\pipe\mxm4-haptic`); std has no AF_UNIX there.
///
/// Unix: an AF_UNIX socket in the per-user runtime dir so it is never
/// reachable outside this user session.
///   Linux: `$XDG_RUNTIME_DIR` (a 0700 tmpfs the kernel reaps on logout).
///   macOS: there is no `XDG_RUNTIME_DIR`; fall back to `$TMPDIR`, which
///   launchd sets per-user to the private 0700 `DARWIN_USER_TEMP_DIR`
///   (`/var/folders/.../T/`) — the closest equivalent. Last-resort `/tmp`
///   keeps the client/daemon able to rendezvous on an unusual session.
pub fn socket_path() -> Option<String> {
    #[cfg(windows)]
    {
        Some(WINDOWS_PIPE_PATH.to_string())
    }
    #[cfg(unix)]
    {
        let dir = std::env::var("XDG_RUNTIME_DIR")
            .ok()
            .filter(|d| !d.is_empty())
            .or_else(|| std::env::var("TMPDIR").ok().filter(|d| !d.is_empty()))
            .unwrap_or_else(|| "/tmp".to_string());
        let dir = dir.trim_end_matches('/');
        Some(format!("{dir}/mxm4-haptic.sock"))
    }
}

/// Connect to the daemon and hand it one waveform name. Fire-and-return:
/// the daemon owns debounce/queue/pacing, so the caller must not block on
/// playback. A missing socket or refused connection is a normal error
/// (daemon not running) and is surfaced to the caller, not swallowed.
#[cfg(unix)]
pub fn send_command(name: &str) -> io::Result<()> {
    let path = socket_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR unset"))?;
    let mut stream = UnixStream::connect(&path)?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    stream.write_all(name.as_bytes())?;
    stream.write_all(b"\n")?;
    Ok(())
}

/// Windows client: open the daemon's named pipe and write one waveform name.
/// A named-pipe client is just a `CreateFileW` open, so std's `OpenOptions`
/// is sufficient — no `windows-sys` on the client side. A missing pipe
/// surfaces as `NotFound` (daemon not running), like the Unix branch.
#[cfg(windows)]
pub fn send_command(name: &str) -> io::Result<()> {
    let path = socket_path()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no named-pipe path"))?;
    let mut pipe = std::fs::OpenOptions::new().write(true).open(&path)?;
    pipe.write_all(name.as_bytes())?;
    pipe.write_all(b"\n")?;
    pipe.flush()?;
    Ok(())
}

// ---------------------------------------------------------------------------
// IPC server (daemon only). The daemon's single AF_UNIX/named-pipe listener,
// abstracted so mxm4-hapticd is platform-agnostic. Each `next_name()` blocks
// for one client and returns its single newline-terminated waveform name,
// trimmed + uppercased (matching waveform_id()'s lookup).
// ---------------------------------------------------------------------------

#[cfg(unix)]
mod ipc_server {
    use std::io::{self, BufRead, BufReader};
    use std::os::unix::net::UnixListener;

    pub struct IpcServer {
        listener: UnixListener,
        endpoint: String,
    }

    impl IpcServer {
        pub fn bind() -> io::Result<Self> {
            let endpoint = super::socket_path()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no runtime dir for socket"))?;
            // Remove any stale socket from an unclean exit before binding.
            let _ = std::fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint)?;
            Ok(Self { listener, endpoint })
        }

        pub fn endpoint(&self) -> &str {
            &self.endpoint
        }

        pub fn next_name(&self) -> io::Result<Option<String>> {
            let (stream, _) = self.listener.accept()?;
            let mut line = String::new();
            let mut reader = BufReader::new(stream);
            if reader.read_line(&mut line).is_err() {
                return Ok(None);
            }
            Ok(Some(line.trim().to_uppercase()))
        }
    }
}

#[cfg(windows)]
mod ipc_server {
    use std::ffi::OsStr;
    use std::io;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;

    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::{ReadFile, PIPE_ACCESS_INBOUND};
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE,
        PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };

    pub struct IpcServer {
        /// UTF-16, NUL-terminated pipe name for CreateNamedPipeW.
        name_wide: Vec<u16>,
        endpoint: String,
    }

    impl IpcServer {
        pub fn bind() -> io::Result<Self> {
            let endpoint = super::socket_path()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no named-pipe path"))?;
            let name_wide = OsStr::new(&endpoint).encode_wide().chain(Some(0)).collect();
            Ok(Self { name_wide, endpoint })
        }

        pub fn endpoint(&self) -> &str {
            &self.endpoint
        }

        /// Create a fresh single-use inbound pipe instance, wait for one client,
        /// read its line, then tear the instance down. PIPE_ACCESS_INBOUND: the
        /// client only ever writes (a waveform name), never reads.
        pub fn next_name(&self) -> io::Result<Option<String>> {
            let pipe = unsafe {
                CreateNamedPipeW(
                    self.name_wide.as_ptr(),
                    PIPE_ACCESS_INBOUND,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                    PIPE_UNLIMITED_INSTANCES,
                    0,
                    512,
                    0,
                    ptr::null::<SECURITY_ATTRIBUTES>(),
                )
            };
            if pipe == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }

            let connected = unsafe { ConnectNamedPipe(pipe, ptr::null_mut()) };
            if connected == 0 {
                let err = unsafe { GetLastError() };
                // A client that connected between create and ConnectNamedPipe
                // yields ERROR_PIPE_CONNECTED — that is still a live client.
                if err != ERROR_PIPE_CONNECTED {
                    unsafe { CloseHandle(pipe) };
                    return Err(io::Error::from_raw_os_error(err as i32));
                }
            }

            let mut buf = [0u8; 64];
            let mut read: u32 = 0;
            let ok = unsafe {
                ReadFile(pipe, buf.as_mut_ptr(), buf.len() as u32, &mut read, ptr::null_mut())
            };
            let name = if ok != 0 && read > 0 {
                Some(String::from_utf8_lossy(&buf[..read as usize]).trim().to_uppercase())
            } else {
                None
            };

            unsafe {
                DisconnectNamedPipe(pipe);
                CloseHandle(pipe);
            }
            Ok(name)
        }
    }
}

pub use ipc_server::IpcServer;

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
// accepts HID++ reports cleanly (others EPIPE or silently discard). macOS and
// Windows report interface_number as -1 and instead expose the Logitech vendor
// usage page 0xFF00 on the HID++ collection, so there it is matched by usage
// page. The daemon accepts either.
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
