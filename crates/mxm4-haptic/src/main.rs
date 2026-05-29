//! mxm4-haptic <WAVEFORM>
//!
//! Fire a haptic waveform on the MX Master 4 via direct HID++ to the Bolt
//! receiver. Fire-and-forget: no ack wait. Cold-start budget ~1-2 ms
//! (vs ~14 ms for the Python predecessor — Python interpreter startup
//! was the entire cost; a native binary removes it).
//!
//! Why this exists, not `solaar config haptic-play` or rules.yaml `Set:`:
//!   - `solaar config haptic-play` spawns a full Solaar CLI (~3.7 s cold)
//!     -> pulse lands AFTER release for any hold shorter than ~4 s.
//!   - rules.yaml `Set: [null, haptic-play, ...]` is in-process but
//!     PlayHapticWaveForm does NOT pass no_reply=True to FeatureRW, so
//!     Solaar waits for an HID++ ack. Bolt-wireless ack variance is
//!     30-300 ms; some pulses feel "missing".
//!   - This binary writes a single HID++ Long report (0x11) directly to
//!     the receiver's hidraw node and exits. No ack wait, no Solaar.
//!
//! Linux-only: reads /sys/class/hidraw and writes /dev/hidraw*. No
//! Windows/macOS port — those platforms drive Logitech haptics through
//! Options+/Logi Options, not raw HID++. See crates/README.md.
//!
//! Cache file ~/.cache/mxm4-haptic.json (written by
//! scripts/linux/config-solaar.sh, extended by this binary):
//!   dev_idx     MX Master 4 pairing slot on the Bolt receiver (1-6)
//!   haptic_idx  HAPTIC (feature 0x19B0) index in the feature list
//!   hidraw      last-known /dev/hidrawN for the Bolt :1.2 interface;
//!               rebuilt on open failure since hidraw numbering is not
//!               stable across reboots.
//!
//! dev_idx / haptic_idx come from `solaar show` at install time (Solaar
//! holds the HID++ session at runtime, so discovery must happen while
//! Solaar is parseable, not via live HID++ contention). This binary only
//! fills in / refreshes the `hidraw` field.

use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::process::ExitCode;

const SYS_HIDRAW: &str = "/sys/class/hidraw";
// Substrings sought in /sys/class/hidraw/hidrawN/device/uevent:
//   HID_ID=0003:0000046D:0000C548  (Bolt receiver VID/PID, upper hex)
//   HID_PHYS=usb-<addr>/input2     (the :1.2 HID++ control interface)
// Only input2 accepts HID++ Long reports cleanly; input0/1/3 either
// EPIPE on the second write or accept-then-discard the first (silent
// no-op). Matching both substrings pins the correct node.
const BOLT_ID_HEX: &str = "046D:0000C548";
const HID_PHYS_IFACE: &str = "/input2\n";

/// (name, id) for every HAPTIC waveform. IDs from
/// logitech_receiver.hidpp20_constants.HapticWaveForms. Note WHISPER
/// COLLISION = 27, not 15 — the firmware enum has a gap between MAD (11)
/// and WHISPER COLLISION (27).
const WAVEFORMS: &[(&str, u8)] = &[
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

fn waveform_id(name: &str) -> Option<u8> {
    let upper = name.to_uppercase();
    WAVEFORMS.iter().find(|(n, _)| *n == upper).map(|(_, id)| *id)
}

fn cache_path() -> Option<String> {
    std::env::var("HOME").ok().map(|h| h + "/.cache/mxm4-haptic.json")
}

/// Minimal extractor for the three flat integer/string fields we need.
/// The cache is written only by us and config-solaar.sh, both emitting a
/// flat one-line object, so a full JSON parser (and the serde_json
/// dependency + build-time cost) is overkill. Returns the value string
/// for `"key":` — caller parses int or strips quotes as needed.
fn json_field<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\"");
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    if let Some(after_quote) = rest.strip_prefix('"') {
        // String value: up to the next unescaped quote.
        let end = after_quote.find('"')?;
        Some(&after_quote[..end])
    } else {
        // Numeric value: up to the next delimiter.
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c.is_whitespace())
            .unwrap_or(rest.len());
        Some(&rest[..end])
    }
}

/// Walk /sys/class/hidraw and return the Bolt :1.2 hidraw device path.
fn discover_hidraw() -> Option<String> {
    let entries = fs::read_dir(SYS_HIDRAW).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let uevent = format!("{SYS_HIDRAW}/{name}/device/uevent");
        let Ok(text) = fs::read_to_string(&uevent) else {
            continue;
        };
        if text.to_uppercase().contains(BOLT_ID_HEX) && text.contains(HID_PHYS_IFACE) {
            return Some(format!("/dev/{name}"));
        }
    }
    None
}

/// Write one HID++ Long report (0x11). No read, no ack wait.
///
/// Packet (20 bytes):
///   [0]  0x11             HID++ Long report id
///   [1]  dev_idx          Bolt pairing slot (1-6)
///   [2]  haptic_idx       HAPTIC feature index in the device feature list
///   [3]  0x40             (fn 4 = PlayHapticWaveForm) << 4 | sw_id 0
///   [4]  waveform_id      single byte (ChoicesValidator byte_count=1)
///   [5..20] 0x00          padding
fn write_packet(path: &str, dev_idx: u8, haptic_idx: u8, wf_id: u8) -> bool {
    let mut pkt = [0u8; 20];
    pkt[0] = 0x11;
    pkt[1] = dev_idx;
    pkt[2] = haptic_idx;
    pkt[3] = 0x40;
    pkt[4] = wf_id;
    let Ok(mut f) = fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc_o_wronly())
        .open(path)
    else {
        return false;
    };
    f.write_all(&pkt).is_ok()
}

/// O_WRONLY without pulling in the libc crate. The std OpenOptions
/// already sets write(true) -> O_WRONLY; custom_flags(0) is a no-op that
/// keeps the call shape uniform and documents intent.
fn libc_o_wronly() -> i32 {
    0
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("Usage: {} <WAVEFORM>", args.first().map(String::as_str).unwrap_or("mxm4-haptic"));
        return ExitCode::from(2);
    }
    let Some(wf_id) = waveform_id(&args[1]) else {
        eprintln!("Unknown waveform: {}", args[1]);
        let names: Vec<&str> = WAVEFORMS.iter().map(|(n, _)| *n).collect();
        eprintln!("Valid: {}", names.join(", "));
        return ExitCode::from(2);
    };

    let Some(cache_file) = cache_path() else {
        eprintln!("mxm4-haptic: HOME not set; cannot locate cache");
        return ExitCode::from(1);
    };
    let Ok(cache) = fs::read_to_string(&cache_file) else {
        eprintln!(
            "mxm4-haptic: missing cache at {cache_file}\n\
             Run 'bash scripts/linux/config-solaar.sh' to populate."
        );
        return ExitCode::from(1);
    };

    let dev_idx: u8 = match json_field(&cache, "dev_idx").and_then(|s| s.parse().ok()) {
        Some(v) => v,
        None => {
            eprintln!("mxm4-haptic: cache missing/invalid dev_idx in {cache_file}");
            return ExitCode::from(1);
        }
    };
    let haptic_idx: u8 = match json_field(&cache, "haptic_idx").and_then(|s| s.parse().ok()) {
        Some(v) => v,
        None => {
            eprintln!("mxm4-haptic: cache missing/invalid haptic_idx in {cache_file}");
            return ExitCode::from(1);
        }
    };

    // Fast path: cached hidraw node.
    if let Some(cached) = json_field(&cache, "hidraw") {
        if write_packet(cached, dev_idx, haptic_idx, wf_id) {
            return ExitCode::SUCCESS;
        }
    }

    // Slow path: rediscover, write, persist the resolved node.
    let Some(node) = discover_hidraw() else {
        eprintln!("mxm4-haptic: no Bolt :1.2 hidraw found");
        return ExitCode::from(1);
    };
    if !write_packet(&node, dev_idx, haptic_idx, wf_id) {
        eprintln!("mxm4-haptic: write rejected at {node}");
        return ExitCode::from(1);
    }
    // Rewrite cache with the resolved node. Non-fatal on failure — the
    // pulse already fired; we just lose the fast path next time.
    let new_cache = format!(
        "{{\"dev_idx\": {dev_idx}, \"haptic_idx\": {haptic_idx}, \"hidraw\": \"{node}\"}}"
    );
    let tmp = format!("{cache_file}.new");
    if fs::write(&tmp, &new_cache).is_ok() {
        let _ = fs::rename(&tmp, &cache_file);
    }
    ExitCode::SUCCESS
}
