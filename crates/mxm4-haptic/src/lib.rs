//! Shared internals for the mxm4-haptic binary set:
//!   mxm4-haptic         thin one-shot client (spawned by Solaar rules)
//!   mxm4-hapticd        haptic daemon (sole owner of the hidraw device)
//!   mxm4-haptic-notify  desktop-notification -> haptic bridge
//!
//! The client and the notification watcher never touch the device: they
//! send a waveform name to the daemon over a local IPC endpoint, and the daemon
//! does discovery, debounce, queueing, and paced playback. This
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
    WAVEFORMS
        .iter()
        .find(|(n, _)| *n == upper)
        .map(|(_, id)| *id)
}

/// All waveform names, for usage/error output.
pub fn waveform_names() -> Vec<&'static str> {
    WAVEFORMS.iter().map(|(n, _)| *n).collect()
}

/// Windows named-pipe endpoint, shared byte-for-byte with the TS client
/// `@h82/mxm4-haptic` (packages/mxm4-haptic/src/index.ts). The two MUST
/// agree. Unlike the per-user POSIX runtime dir, this is the machine-global
/// `\\.\pipe` namespace. The server reserves its first instance for its full
/// lifetime and applies an explicit current-user/system-only DACL.
#[cfg(windows)]
pub const WINDOWS_PIPE_PATH: &str = r"\\.\pipe\mxm4-haptic";

/// Rendezvous endpoint between the clients and the daemon.
///
/// Windows: a named pipe (`\\.\pipe\mxm4-haptic`); std has no AF_UNIX there.
///
/// Unix: an AF_UNIX socket in the per-user runtime dir, bound with owner-only
/// permissions so it is never reachable outside this user session.
///   Linux: `$XDG_RUNTIME_DIR` (a 0700 tmpfs the kernel reaps on logout).
///   macOS: there is no `XDG_RUNTIME_DIR`; fall back to `$TMPDIR`, which
///   launchd sets per-user to the private 0700 `DARWIN_USER_TEMP_DIR`
///   (`/var/folders/.../T/`) — the closest equivalent. Last-resort `/tmp`
///   keeps the client/daemon able to rendezvous on an unusual session while the
///   socket file mode still enforces owner-only access.
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
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    pub struct IpcServer {
        listener: UnixListener,
        endpoint: String,
    }

    impl IpcServer {
        pub fn bind() -> io::Result<Self> {
            let endpoint = super::socket_path().ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "no runtime dir for socket")
            })?;
            // Remove any stale socket from an unclean exit before binding.
            let _ = std::fs::remove_file(&endpoint);
            let listener = UnixListener::bind(&endpoint)?;
            std::fs::set_permissions(&endpoint, std::fs::Permissions::from_mode(0o600))?;
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
    use std::ffi::{c_void, OsStr};
    use std::io;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;

    use windows_sys::core::PWSTR;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, LocalFree, ERROR_BROKEN_PIPE, ERROR_INSUFFICIENT_BUFFER,
        ERROR_NO_DATA, ERROR_PIPE_CONNECTED, ERROR_PIPE_NOT_CONNECTED, HANDLE, HLOCAL,
        INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{
        GetTokenInformation, TokenUser, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY,
        TOKEN_USER,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        ReadFile, FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_INBOUND,
    };
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE,
        PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    struct OwnedHandle(HANDLE);

    // Windows kernel handles are process-wide. This wrapper owns one handle,
    // moves it with the server thread, and closes it exactly once in Drop.
    unsafe impl Send for OwnedHandle {}

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if self.0 != INVALID_HANDLE_VALUE {
                unsafe { CloseHandle(self.0) };
            }
        }
    }

    struct LocalAllocation(HLOCAL);

    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    LocalFree(self.0);
                }
            }
        }
    }

    fn current_user_sid() -> io::Result<String> {
        let mut token = INVALID_HANDLE_VALUE;
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let token = OwnedHandle(token);

        let mut required = 0u32;
        unsafe {
            GetTokenInformation(token.0, TokenUser, ptr::null_mut(), 0, &mut required);
        }
        if required == 0 || unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER {
            return Err(io::Error::last_os_error());
        }

        let word_size = std::mem::size_of::<usize>();
        let mut buffer = vec![0usize; (required as usize + word_size - 1) / word_size];
        if unsafe {
            GetTokenInformation(
                token.0,
                TokenUser,
                buffer.as_mut_ptr().cast::<c_void>(),
                required,
                &mut required,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }

        let token_user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
        let mut sid_text: PWSTR = ptr::null_mut();
        if unsafe { ConvertSidToStringSidW(token_user.User.Sid, &mut sid_text) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let sid_allocation = LocalAllocation(sid_text.cast::<c_void>());
        let length = unsafe {
            (0..)
                .take_while(|offset| *sid_text.add(*offset) != 0)
                .count()
        };
        let sid = String::from_utf16(unsafe { std::slice::from_raw_parts(sid_text, length) })
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        drop(sid_allocation);
        Ok(sid)
    }

    fn security_descriptor() -> io::Result<LocalAllocation> {
        let sid = current_user_sid()?;
        // Protected DACL: the interactive owner plus LocalSystem. No broad
        // administrator, authenticated-user, built-in-user, or world ACE is
        // present, so a different human SID cannot write through group access.
        let sddl = format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)");
        let sddl_wide: Vec<u16> = OsStr::new(&sddl).encode_wide().chain(Some(0)).collect();
        let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl_wide.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(LocalAllocation(descriptor))
    }

    pub struct IpcServer {
        pipe: OwnedHandle,
        endpoint: String,
    }

    impl IpcServer {
        pub fn bind() -> io::Result<Self> {
            let endpoint = super::socket_path()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no named-pipe path"))?;
            let name_wide: Vec<u16> = OsStr::new(&endpoint).encode_wide().chain(Some(0)).collect();
            let descriptor = security_descriptor()?;
            let attributes = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: 0,
            };
            let pipe = unsafe {
                CreateNamedPipeW(
                    name_wide.as_ptr(),
                    PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                    1,
                    0,
                    512,
                    0,
                    &attributes,
                )
            };
            if pipe == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }
            Ok(Self {
                pipe: OwnedHandle(pipe),
                endpoint,
            })
        }

        pub fn endpoint(&self) -> &str {
            &self.endpoint
        }

        /// Reuse the reserved first instance for every client. Keeping this
        /// handle open for `IpcServer`'s lifetime makes a prebound collision a
        /// deterministic bind failure and prevents an ownership gap between
        /// commands.
        pub fn next_name(&self) -> io::Result<Option<String>> {
            let connected = unsafe { ConnectNamedPipe(self.pipe.0, ptr::null_mut()) };
            if connected == 0 {
                let err = unsafe { GetLastError() };
                if err != ERROR_PIPE_CONNECTED {
                    return Err(io::Error::from_raw_os_error(err as i32));
                }
            }

            let mut buf = [0u8; 64];
            let mut read = 0u32;
            let ok = unsafe {
                ReadFile(
                    self.pipe.0,
                    buf.as_mut_ptr(),
                    buf.len() as u32,
                    &mut read,
                    ptr::null_mut(),
                )
            };
            let read_error = if ok == 0 {
                Some(io::Error::last_os_error())
            } else {
                None
            };
            unsafe {
                DisconnectNamedPipe(self.pipe.0);
            }
            if let Some(error) = read_error {
                if matches!(
                    error.raw_os_error(),
                    Some(code)
                        if code == ERROR_BROKEN_PIPE as i32
                            || code == ERROR_NO_DATA as i32
                            || code == ERROR_PIPE_NOT_CONNECTED as i32
                ) {
                    return Ok(None);
                }
                return Err(error);
            }
            if read == 0 {
                return Ok(None);
            }
            Ok(Some(
                String::from_utf8_lossy(&buf[..read as usize])
                    .trim()
                    .to_uppercase(),
            ))
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

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::sync::{Mutex, OnceLock};

    #[cfg(unix)]
    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[cfg(windows)]
    #[test]
    fn windows_pipe_reserves_first_instance_and_releases_on_drop() {
        let owner = IpcServer::bind().expect("first named-pipe instance");
        assert!(
            IpcServer::bind().is_err(),
            "a second server must not join the fixed endpoint"
        );
        drop(owner);
        IpcServer::bind().expect("ownership must converge after the collision is removed");
    }

    // -----------------------------------------------------------------------
    // Step 2: Waveform catalogue
    // -----------------------------------------------------------------------

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
        // ids 0..=14 plus 27 (WHISPER COLLISION gap in firmware enum)
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

    // -----------------------------------------------------------------------
    // Step 3: Packet builders
    // -----------------------------------------------------------------------

    #[test]
    fn build_play_packet_layout() {
        let pkt = build_play_packet(1, 9, 27);
        assert_eq!(pkt.len(), 20);
        assert_eq!(pkt[0], 0x11);
        assert_eq!(pkt[1], 1);
        assert_eq!(pkt[2], 9);
        assert_eq!(pkt[3], 0x40);
        assert_eq!(pkt[4], 27);
        // bytes 5..20 must all be zero
        assert!(pkt[5..].iter().all(|&b| b == 0));
    }

    #[test]
    fn build_get_feature_layout() {
        let pkt = build_get_feature(2, 0x19, 0xB0, 0x0E);
        assert_eq!(pkt, [0x10, 2, 0x00, 0x0E, 0x19, 0xB0, 0x00]);
    }

    #[test]
    fn build_get_feature_sw_id_masked() {
        // sw_id 0xFE → low nibble 0x0E
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

    // -----------------------------------------------------------------------
    // Step 4: classify_root_reply
    // -----------------------------------------------------------------------

    #[test]
    fn classify_root_reply_success_short() {
        // [0x10, dev, 0x00, sw, idx, 0, 0] → FeatureIndex(idx)
        let buf = [0x10u8, 0x01, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(
            classify_root_reply(&buf, 0x01, 0x0E),
            RootReply::FeatureIndex(0x05)
        );
    }

    #[test]
    fn classify_root_reply_success_long() {
        // 20-byte long report starting [0x11, dev, 0x00, sw, idx, ...]
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
        // sub_id 0xFF, buf[3]==0x00, buf[4]==sw, code at buf[5]
        let buf = [0x10u8, 0x01, 0xFF, 0x00, 0x0E, 0x06, 0x00];
        assert_eq!(
            classify_root_reply(&buf, 0x01, 0x0E),
            RootReply::Hidpp20Error(0x06)
        );
    }

    #[test]
    fn classify_root_reply_hidpp10_error() {
        // sub_id 0x8F, buf[3]==0x00, buf[4]==sw, code at buf[5]
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
        // success path but sw_id mismatch
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
        // report id 0x11 but only 7 bytes (< 20)
        let buf = [0x11u8, 0x01, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    #[test]
    fn classify_root_reply_unknown_report_id() {
        let buf = [0x20u8, 0x01, 0x00, 0x0E, 0x05, 0x00, 0x00];
        assert_eq!(classify_root_reply(&buf, 0x01, 0x0E), RootReply::NotForUs);
    }

    // -----------------------------------------------------------------------
    // Step 5: parse_connection_notification
    // -----------------------------------------------------------------------

    #[test]
    fn parse_connection_notification_link_established() {
        // bit 0x40 clear → link established
        let buf = [0x10u8, 5, 0x41, 0, 0x00, 0, 0];
        assert_eq!(parse_connection_notification(&buf), Some((5, true)));
    }

    #[test]
    fn parse_connection_notification_link_lost() {
        // bit 0x40 set → link lost
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

    // -----------------------------------------------------------------------
    // Step 6: socket_path (unix only, all env assertions in ONE test)
    // -----------------------------------------------------------------------

    #[cfg(unix)]
    #[test]
    fn socket_path_unix_env_resolution() {
        use std::env;
        let _guard = env_lock().lock().unwrap();

        // Save originals
        let orig_xdg = env::var("XDG_RUNTIME_DIR").ok();
        let orig_tmp = env::var("TMPDIR").ok();

        // Case 1: XDG_RUNTIME_DIR with trailing slash → trimmed
        unsafe {
            env::set_var("XDG_RUNTIME_DIR", "/run/user/1000/");
            env::remove_var("TMPDIR");
        }
        assert_eq!(
            socket_path(),
            Some("/run/user/1000/mxm4-haptic.sock".to_string())
        );

        // Case 2: XDG unset, TMPDIR set
        unsafe {
            env::remove_var("XDG_RUNTIME_DIR");
            env::set_var("TMPDIR", "/var/tmpx");
        }
        assert_eq!(
            socket_path(),
            Some("/var/tmpx/mxm4-haptic.sock".to_string())
        );

        // Case 3: both unset → /tmp fallback
        unsafe {
            env::remove_var("XDG_RUNTIME_DIR");
            env::remove_var("TMPDIR");
        }
        assert_eq!(socket_path(), Some("/tmp/mxm4-haptic.sock".to_string()));

        // Restore originals
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

    #[cfg(unix)]
    #[test]
    fn ipc_server_socket_is_owner_only() {
        use std::env;
        use std::os::unix::fs::PermissionsExt;
        let _guard = env_lock().lock().unwrap();

        let orig_xdg = env::var("XDG_RUNTIME_DIR").ok();
        let orig_tmp = env::var("TMPDIR").ok();
        let dir = env::temp_dir().join(format!("mxm4-haptic-test-{}", std::process::id()));
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

        let endpoint = server.endpoint().to_string();
        drop(server);
        let _ = std::fs::remove_file(endpoint);
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
