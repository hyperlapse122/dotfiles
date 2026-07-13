//! mxm4-haptic-notify
//!
//! Bridges freedesktop desktop notifications to a haptic pulse. A new
//! notification is a `Notify` METHOD CALL to the notification daemon (not
//! a signal), so it can only be observed by eavesdropping the session bus
//! — `gdbus monitor` watches signals and would miss it. We spawn
//! `dbus-monitor` (a true bus monitor) filtered to that method call,
//! parse each message block, and forward a waveform to mxm4-hapticd via
//! the shared socket. The daemon applies its own debounce/queue; the
//! extra gap here just avoids hammering it on notification storms.
//!
//! Desktop-agnostic: `org.freedesktop.Notifications` is the freedesktop
//! spec interface, and we match the sending APP's method call — not
//! anything the server does — so it works identically whether the
//! notification server is KDE's plasmashell or GNOME Shell (which serves
//! that name itself). Caveat: GNOME-native GTK4/GApplication apps that use
//! GNotification talk to `org.gtk.Notifications` instead and are not seen;
//! libnotify/portal/Electron/browser notifications all use the fdo call.
//!
//! Additionally watches the SYSTEM bus for UPower `PropertiesChanged`
//! signals under `/org/freedesktop/UPower/devices` and pulses when a
//! battery's WarningLevel drops to low/critical — the flagship case being
//! the mouse's own battery (hid-logitech-hidpp exposes it as a
//! power_supply, surfaced by UPower). Broadcast signals need no monitor
//! privileges: dbus-monitor falls back from BecomeMonitor (denied to
//! normal users on the system bus) to a plain match rule, which still
//! receives them.
//!
//! Tunables (env):
//!   MXM4_NOTIFY_MIN_GAP_MS   min ms between forwarded pulses (default 800)
//!   MXM4_NOTIFY_SKIP_REPLACES "0" to also pulse on notification *updates*
//!                            (replaces_id != 0, e.g. progress / now-playing);
//!                            default skips them
//!   MXM4_NOTIFY_DENY         comma-separated app_name list to ignore
//!   MXM4_NOTIFY_BATTERY      "0"/"false" to disable the UPower battery
//!                            watcher (default enabled)
//!
//! Urgency -> waveform: low (0) is ignored, normal (1) -> SUBTLE COLLISION,
//! critical (2) -> SHARP COLLISION. Battery WarningLevel -> waveform:
//! low (3) -> ANGRY ALERT, critical/action (>=4) -> MAD, fired only on the
//! TRANSITION into that level per device. Linux-only (D-Bus +
//! dbus-monitor). See crates/README.md.

// Linux-only: it eavesdrops D-Bus via `dbus-monitor`.
// macOS/Windows expose no public API to observe other apps' notifications, so
// off Linux this binary compiles to a stub that exits with a clear message
// (the [[bin]] target must still exist for `cargo build` on every platform).
use std::process::ExitCode;

#[cfg(target_os = "linux")]
use std::collections::HashMap;
#[cfg(target_os = "linux")]
use std::io::{BufRead, BufReader};
#[cfg(target_os = "linux")]
use std::process::{Command, Stdio};
#[cfg(target_os = "linux")]
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// First `string "..."` arg in a dbus-monitor message block = app_name.
#[cfg(target_os = "linux")]
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
#[cfg(target_os = "linux")]
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
#[cfg(target_os = "linux")]
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

/// Object path from a dbus-monitor header line: the `path=...` field, which
/// runs up to the `;` separating it from `interface=`.
#[cfg(target_os = "linux")]
fn signal_path(text: &str) -> Option<&str> {
    for line in text.lines() {
        if let Some(i) = line.find("path=") {
            let rest = &line[i + 5..];
            let end = rest.find(';').unwrap_or(rest.len());
            return Some(&rest[..end]);
        }
    }
    None
}

/// `WarningLevel` value in a UPower PropertiesChanged block: the `uint32 N`
/// (variant-wrapped) line that follows the `string "WarningLevel"` dict key.
/// UPower enum: 0 unknown, 1 none, 2 discharging, 3 low, 4 critical, 5 action.
#[cfg(target_os = "linux")]
fn warning_level(text: &str) -> Option<u32> {
    let mut after_key = false;
    for line in text.lines() {
        if line.contains("\"WarningLevel\"") {
            after_key = true;
            continue;
        }
        if after_key {
            if let Some(i) = line.find("uint32 ") {
                return line[i + 7..].trim().parse().ok();
            }
        }
    }
    None
}

/// Waveform for a per-device WarningLevel change, or None when it should
/// not pulse. Fires only on a WORSENING transition into low/critical
/// (`new > prev`), so repeats of the same level and recoveries stay silent;
/// a transition back to none records the lower level, which re-arms the
/// device for a later re-drop.
#[cfg(target_os = "linux")]
fn battery_waveform(prev: u32, new: u32) -> Option<&'static str> {
    if new < 3 || new <= prev {
        return None;
    }
    Some(if new >= 4 { "MAD" } else { "ANGRY ALERT" })
}

/// UPower battery watcher (own thread): second dbus-monitor on the SYSTEM
/// bus, same block parsing and daemon-send path as the Notify watcher.
/// Battery events are rare, so the per-path transition tracking is the real
/// dedupe; the shared min-gap value just guards against a device flapping.
#[cfg(target_os = "linux")]
fn battery_watch(min_gap: Duration) {
    let mut child = match Command::new("dbus-monitor")
        .args([
            "--system",
            "type='signal',interface='org.freedesktop.DBus.Properties',\
             member='PropertiesChanged',\
             path_namespace='/org/freedesktop/UPower/devices'",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            // No system-bus watch is a degraded mode, not a fatal one: the
            // notification bridge keeps running.
            eprintln!("mxm4-haptic-notify: cannot spawn system dbus-monitor: {e}");
            return;
        }
    };
    let reader = BufReader::new(child.stdout.take().expect("piped stdout"));
    let started = Instant::now();

    let mut block: Vec<String> = Vec::new();
    let mut levels: HashMap<String, u32> = HashMap::new();
    let mut last = Instant::now() - Duration::from_secs(3600);

    let mut handle = |block: &mut Vec<String>| {
        let text = std::mem::take(block).join("\n");
        if !text.contains("member=PropertiesChanged") {
            return;
        }
        // Blocks without a WarningLevel change (percentage ticks, icon
        // updates, ...) parse to None and are skipped.
        let Some(level) = warning_level(&text) else {
            return;
        };
        let Some(path) = signal_path(&text) else {
            return;
        };
        // First sighting counts as a transition from none (1), so a device
        // that appears already-low still pulses once.
        let prev = levels.insert(path.to_string(), level).unwrap_or(1);
        let Some(waveform) = battery_waveform(prev, level) else {
            return;
        };
        if last.elapsed() < min_gap {
            return;
        }
        last = Instant::now();
        let _ = mxm4_haptic::send_command(waveform);
    };

    for line in reader.lines().map_while(Result::ok) {
        if line.starts_with("method call ")
            || line.starts_with("signal ")
            || line.starts_with("method return ")
            || line.starts_with("error ")
        {
            handle(&mut block);
        }
        let value_line = line.contains("uint32 ");
        block.push(line);
        // Flush EAGERLY once the WarningLevel value line has arrived: the
        // next-header flush alone would stall this rare signal until the
        // next UPower message, which may be minutes away (or never — a
        // dying mouse stops talking). handle() consumes the block; the
        // message's leftover lines form a headerless tail the next flush
        // ignores.
        if value_line {
            let text = block.join("\n");
            if text.contains("member=PropertiesChanged") && warning_level(&text).is_some() {
                handle(&mut block);
            }
        }
    }
    handle(&mut block);

    // dbus-monitor exited. Mirror the session watcher — exit nonzero so the
    // unit's Restart=always revives BOTH watchers — unless it died right
    // away (e.g. no system bus at all), where restarting would just spin:
    // then drop battery watching and keep the notification bridge alive.
    if started.elapsed() > Duration::from_secs(60) {
        eprintln!("mxm4-haptic-notify: system dbus-monitor exited; restarting");
        std::process::exit(1);
    }
    eprintln!("mxm4-haptic-notify: system dbus-monitor exited early; battery watch disabled");
}

#[cfg(not(target_os = "linux"))]
fn main() -> ExitCode {
    eprintln!(
        "mxm4-haptic-notify is Linux-only (D-Bus desktop-notification bridge); \
         not supported on this platform."
    );
    ExitCode::from(1)
}

#[cfg(target_os = "linux")]
fn main() -> ExitCode {
    let min_gap = Duration::from_millis(env_u64("MXM4_NOTIFY_MIN_GAP_MS", 800));
    let skip_replaces = std::env::var("MXM4_NOTIFY_SKIP_REPLACES")
        .map(|v| v != "0")
        .unwrap_or(true);
    let deny: Vec<String> = std::env::var("MXM4_NOTIFY_DENY")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let battery = std::env::var("MXM4_NOTIFY_BATTERY")
        .map(|v| v != "0" && !v.eq_ignore_ascii_case("false"))
        .unwrap_or(true);

    if battery {
        std::thread::spawn(move || battery_watch(min_gap));
    }

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

        if deny.contains(&app) {
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

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    // A representative dbus-monitor message block for a Notify method call.
    const NOTIFY_BLOCK: &str = r#"method call time=1700000000.0 sender=:1.100 -> destination=org.freedesktop.Notifications serial=42 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=Notify
   string "Firefox"
   uint32 0
   string "firefox"
   string "Download complete"
   string "report.pdf finished downloading"
   array [
   ]
   array [
      dict entry(
         string "urgency"
         variant             byte 2
      )
   ]
   int32 -1"#;

    #[test]
    fn first_string_returns_app_name() {
        assert_eq!(first_string(NOTIFY_BLOCK).as_deref(), Some("Firefox"));
    }

    #[test]
    fn first_string_none_when_no_string_line() {
        assert_eq!(first_string("uint32 5\nint32 -1"), None);
    }

    #[test]
    fn first_string_keeps_embedded_quotes_via_last_quote() {
        // rfind('"') is greedy: an app_name containing quotes is returned whole.
        assert_eq!(
            first_string("   string \"a \"quoted\" name\"").as_deref(),
            Some("a \"quoted\" name")
        );
    }

    #[test]
    fn first_uint32_returns_replaces_id() {
        assert_eq!(first_uint32(NOTIFY_BLOCK), Some(0));
    }

    #[test]
    fn first_uint32_first_match_wins() {
        assert_eq!(first_uint32("uint32 7\nuint32 9"), Some(7));
    }

    #[test]
    fn first_uint32_none_when_absent() {
        assert_eq!(first_uint32("string \"x\"\nint32 -1"), None);
    }

    #[test]
    fn urgency_byte_reads_value_after_urgency_entry() {
        assert_eq!(urgency_byte(NOTIFY_BLOCK), Some(2));
    }

    #[test]
    fn urgency_byte_normal_urgency() {
        let block = "dict entry(\n   string \"urgency\"\n   variant             byte 1\n)";
        assert_eq!(urgency_byte(block), Some(1));
    }

    #[test]
    fn urgency_byte_none_when_no_urgency_hint() {
        // No urgency entry at all -> None (the caller defaults to normal=1).
        assert_eq!(urgency_byte("string \"category\"\nvariant byte 3"), None);
    }

    #[test]
    fn urgency_byte_none_when_urgency_has_no_following_byte() {
        assert_eq!(urgency_byte("string \"urgency\""), None);
    }

    // A real dbus-monitor block for a UPower WarningLevel change, captured
    // on the system bus (variant-wrapped uint32 inside the a{sv} dict).
    const UPOWER_BLOCK: &str = r#"signal time=1783912514.903573 sender=:1.307 -> destination=(null destination) serial=2 path=/org/freedesktop/UPower/devices/battery_hidpp_battery_0; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged
   string "org.freedesktop.UPower.Device"
   array [
      dict entry(
         string "WarningLevel"
         variant             uint32 3
      )
      dict entry(
         string "IconName"
         variant             string "battery-caution-symbolic"
      )
   ]
   array [
   ]"#;

    #[test]
    fn signal_path_extracts_device_path() {
        assert_eq!(
            signal_path(UPOWER_BLOCK),
            Some("/org/freedesktop/UPower/devices/battery_hidpp_battery_0")
        );
    }

    #[test]
    fn signal_path_none_without_path_field() {
        assert_eq!(signal_path("string \"x\"\nuint32 3"), None);
    }

    #[test]
    fn warning_level_reads_variant_uint32() {
        assert_eq!(warning_level(UPOWER_BLOCK), Some(3));
    }

    #[test]
    fn warning_level_none_when_other_properties_change() {
        // Percentage tick without a WarningLevel entry -> None (skipped).
        let block = "dict entry(\n   string \"Percentage\"\n   variant             double 42\n)";
        assert_eq!(warning_level(block), None);
    }

    #[test]
    fn warning_level_none_when_key_has_no_following_uint32() {
        assert_eq!(warning_level("string \"WarningLevel\""), None);
    }

    #[test]
    fn battery_waveform_transition_matrix() {
        // Worsening transitions fire.
        assert_eq!(battery_waveform(1, 3), Some("ANGRY ALERT"));
        assert_eq!(battery_waveform(3, 4), Some("MAD"));
        assert_eq!(battery_waveform(1, 4), Some("MAD"));
        assert_eq!(battery_waveform(4, 5), Some("MAD"));
        // Repeats, recoveries, and sub-low levels stay silent.
        assert_eq!(battery_waveform(3, 3), None);
        assert_eq!(battery_waveform(4, 3), None);
        assert_eq!(battery_waveform(3, 1), None);
        assert_eq!(battery_waveform(1, 2), None);
        assert_eq!(battery_waveform(0, 1), None);
        // Back to none (recorded as prev) re-arms a later re-drop.
        assert_eq!(battery_waveform(1, 3), Some("ANGRY ALERT"));
    }
}
