//! mxm4-haptic-notify
//!
//! Bridges freedesktop/KDE desktop notifications to a haptic pulse. A new
//! notification is a `Notify` METHOD CALL to the notification daemon (not
//! a signal), so it can only be observed by eavesdropping the session bus
//! — `gdbus monitor` watches signals and would miss it. We spawn
//! `dbus-monitor` (a true bus monitor) filtered to that method call,
//! parse each message block, and forward a waveform to mxm4-hapticd via
//! the shared socket. The daemon applies its own debounce/queue; the
//! extra gap here just avoids hammering it on notification storms.
//!
//! Tunables (env):
//!   MXM4_NOTIFY_MIN_GAP_MS   min ms between forwarded pulses (default 800)
//!   MXM4_NOTIFY_SKIP_REPLACES "0" to also pulse on notification *updates*
//!                            (replaces_id != 0, e.g. progress / now-playing);
//!                            default skips them
//!   MXM4_NOTIFY_DENY         comma-separated app_name list to ignore
//!
//! Urgency -> waveform: low (0) is ignored, normal (1) -> SUBTLE COLLISION,
//! critical (2) -> SHARP COLLISION. Linux/KDE-only (session bus +
//! dbus-monitor). See crates/README.md.

use std::io::{BufRead, BufReader};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// First `string "..."` arg in a dbus-monitor message block = app_name.
fn first_string(text: &str) -> Option<String> {
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix("string \"") {
            let end = rest.rfind('"')?;
            return Some(rest[..end].to_string());
        }
    }
    None
}

/// First `uint32 N` arg = replaces_id.
fn first_uint32(text: &str) -> Option<u32> {
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix("uint32 ") {
            return rest.trim().parse().ok();
        }
    }
    None
}

/// `urgency` hint is a byte in the hints dict: the `byte N` line that
/// follows the `string "urgency"` entry. Absent => spec default normal (1).
fn urgency_byte(text: &str) -> Option<u8> {
    let mut after_urgency = false;
    for line in text.lines() {
        if line.contains("\"urgency\"") {
            after_urgency = true;
            continue;
        }
        if after_urgency {
            if let Some(i) = line.find("byte ") {
                return line[i + 5..].trim().parse().ok();
            }
        }
    }
    None
}

fn main() -> ExitCode {
    let min_gap = Duration::from_millis(env_u64("MXM4_NOTIFY_MIN_GAP_MS", 800));
    let skip_replaces =
        std::env::var("MXM4_NOTIFY_SKIP_REPLACES").map(|v| v != "0").unwrap_or(true);
    let deny: Vec<String> = std::env::var("MXM4_NOTIFY_DENY")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let mut child = match Command::new("dbus-monitor")
        .args([
            "--session",
            "interface='org.freedesktop.Notifications',member='Notify'",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("mxm4-haptic-notify: cannot spawn dbus-monitor: {e}");
            return ExitCode::from(1);
        }
    };
    let reader = BufReader::new(child.stdout.take().expect("piped stdout"));

    let mut block: Vec<String> = Vec::new();
    let mut last = Instant::now() - Duration::from_secs(3600);

    let handle = |block: &mut Vec<String>, last: &mut Instant| {
        let text = std::mem::take(block).join("\n");
        if !text.contains("member=Notify") {
            return;
        }
        let app = first_string(&text).unwrap_or_default();
        let replaces = first_uint32(&text).unwrap_or(0);
        let urgency = urgency_byte(&text).unwrap_or(1);

        if deny.iter().any(|d| *d == app) {
            return;
        }
        if skip_replaces && replaces != 0 {
            return;
        }
        let waveform = match urgency {
            0 => return,
            2 => "SHARP COLLISION",
            _ => "SUBTLE COLLISION",
        };
        if last.elapsed() < min_gap {
            return;
        }
        *last = Instant::now();
        let _ = mxm4_haptic::send_command(waveform);
    };

    // dbus-monitor prints one message per block; a new header line starts
    // the next message, so flush the accumulated block on each header.
    for line in reader.lines().map_while(Result::ok) {
        if line.starts_with("method call ")
            || line.starts_with("signal ")
            || line.starts_with("method return ")
            || line.starts_with("error ")
        {
            handle(&mut block, &mut last);
        }
        block.push(line);
    }
    handle(&mut block, &mut last);

    // dbus-monitor exited (bus restart, etc.) — return nonzero so the
    // systemd unit's Restart=always brings us back.
    ExitCode::from(1)
}
