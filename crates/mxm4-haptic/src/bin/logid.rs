//! logid — Headless Logitech device daemon.
//!
//! Sole owner of the Bolt receiver's HID++ session (interface 2).
//! Manages MX Master 4 haptic playback, HID++ 2.0 battery polling,
//! session D-Bus StatusNotifierItem (SNI) tray integration, and
//! low-battery desktop notifications.

use std::io::Write;
use std::process::ExitCode;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use hidapi::{HidApi, HidDevice};
use mxm4_haptic as lib;

fn pacing_ms() -> u64 {
    std::env::var("LOGID_PACING_MS")
        .or_else(|_| std::env::var("MXM4D_PACING_MS"))
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(180)
}

fn debounce_ms() -> u64 {
    std::env::var("LOGID_DEBOUNCE_MS")
        .or_else(|_| std::env::var("MXM4D_DEBOUNCE_MS"))
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(120)
}

fn poll_ms() -> i32 {
    std::env::var("LOGID_POLL_MS")
        .or_else(|_| std::env::var("MXM4D_POLL_MS"))
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8)
}

fn battery_poll_interval() -> Duration {
    let secs = std::env::var("LOGID_BATTERY_POLL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(300);
    Duration::from_secs(secs)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BatteryFeatureKind {
    LevelStatus1000(u8),
    Unified1004(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Target {
    pub dev_idx: u8,
    pub haptic_idx: u8,
    pub battery_feature: Option<BatteryFeatureKind>,
}

fn remaining_ms(deadline: Instant) -> Option<i32> {
    let now = Instant::now();
    if now >= deadline {
        return None;
    }
    Some((deadline - now).as_millis().min(i32::MAX as u128) as i32)
}

fn get_feature_index(
    device: &HidDevice,
    dev: u8,
    feat_hi: u8,
    feat_lo: u8,
    connected: &mut [bool; 7],
) -> Option<u8> {
    let req = lib::build_get_feature(dev, feat_hi, feat_lo, lib::SW_ID);
    if device.write(&req).is_err() {
        return None;
    }
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut buf = [0u8; 64];
    while let Some(remaining) = remaining_ms(deadline) {
        match device.read_timeout(&mut buf, remaining) {
            Ok(0) => {}
            Ok(n) => {
                let report = &buf[..n];
                if let Some((d, established)) = lib::parse_connection_notification(report) {
                    if (d as usize) < connected.len() {
                        connected[d as usize] = established;
                    }
                    continue;
                }
                match lib::classify_root_reply(report, dev, lib::SW_ID) {
                    lib::RootReply::FeatureIndex(idx) => return Some(idx),
                    lib::RootReply::Hidpp20Error(_) | lib::RootReply::Hidpp10Error(_) => {
                        return None
                    }
                    lib::RootReply::NotForUs => continue,
                }
            }
            Err(_) => return None,
        }
    }
    None
}

fn read_battery_status(
    device: &HidDevice,
    target: Target,
    connected: &mut [bool; 7],
) -> Option<lib::battery::BatteryInfo> {
    let kind = target.battery_feature?;
    let req = match kind {
        BatteryFeatureKind::LevelStatus1000(idx) => {
            lib::battery::build_get_battery_level_status(target.dev_idx, idx, lib::SW_ID)
        }
        BatteryFeatureKind::Unified1004(idx) => {
            lib::battery::build_get_unified_battery_status(target.dev_idx, idx, lib::SW_ID)
        }
    };
    if device.write(&req).is_err() {
        return None;
    }
    let deadline = Instant::now() + Duration::from_millis(1500);
    let mut buf = [0u8; 64];
    while let Some(remaining) = remaining_ms(deadline) {
        match device.read_timeout(&mut buf, remaining) {
            Ok(0) => {}
            Ok(n) => {
                let report = &buf[..n];
                if let Some((d, established)) = lib::parse_connection_notification(report) {
                    if (d as usize) < connected.len() {
                        connected[d as usize] = established;
                    }
                    continue;
                }
                let reply = match kind {
                    BatteryFeatureKind::LevelStatus1000(idx) => {
                        lib::battery::classify_battery_1000_reply(
                            report,
                            target.dev_idx,
                            idx,
                            lib::SW_ID,
                        )
                    }
                    BatteryFeatureKind::Unified1004(idx) => {
                        lib::battery::classify_battery_1004_reply(
                            report,
                            target.dev_idx,
                            idx,
                            lib::SW_ID,
                        )
                    }
                };
                match reply {
                    lib::battery::BatteryReply::Status(info) => return Some(info),
                    lib::battery::BatteryReply::HidppError(_) => return None,
                    lib::battery::BatteryReply::NotForUs => continue,
                }
            }
            Err(_) => return None,
        }
    }
    None
}

fn discover(device: &HidDevice, connected: &mut [bool; 7]) -> Option<Target> {
    let _ = device.write(&lib::REANNOUNCE_DEVICES);
    let deadline = Instant::now() + Duration::from_millis(600);
    let mut buf = [0u8; 64];
    while let Some(remaining) = remaining_ms(deadline) {
        match device.read_timeout(&mut buf, remaining) {
            Ok(0) => {}
            Ok(n) => {
                if let Some((dev, established)) = lib::parse_connection_notification(&buf[..n]) {
                    if (dev as usize) < connected.len() {
                        connected[dev as usize] = established;
                    }
                }
            }
            Err(_) => return None,
        }
    }

    let slots: Vec<u8> = (1u8..=6).filter(|d| connected[*d as usize]).collect();
    for dev in slots {
        if let Some(haptic_idx) = get_feature_index(
            device,
            dev,
            lib::HAPTIC_FEATURE_HI,
            lib::HAPTIC_FEATURE_LO,
            connected,
        ) {
            let battery_feature = if let Some(b_idx) = get_feature_index(
                device,
                dev,
                lib::battery::BATTERY_FEATURE_1000_HI,
                lib::battery::BATTERY_FEATURE_1000_LO,
                connected,
            ) {
                Some(BatteryFeatureKind::LevelStatus1000(b_idx))
            } else {
                get_feature_index(
                    device,
                    dev,
                    lib::battery::BATTERY_FEATURE_1004_HI,
                    lib::battery::BATTERY_FEATURE_1004_LO,
                    connected,
                )
                .map(BatteryFeatureKind::Unified1004)
            };

            eprintln!(
                "logid: MX Master 4 at slot {dev}, HAPTIC {haptic_idx}, BATTERY {:?}",
                battery_feature
            );
            return Some(Target {
                dev_idx: dev,
                haptic_idx,
                battery_feature,
            });
        }
    }
    None
}

struct PlayState<'a> {
    connected: &'a mut [bool; 7],
    target: &'a mut Option<Target>,
    dirty: &'a mut bool,
    last_play: &'a mut Instant,
    last_discover: &'a mut Instant,
    debounce: Duration,
    pacing: Duration,
}

fn handle_play(wf_id: u8, device: &HidDevice, st: &mut PlayState) {
    let gap = st.last_play.elapsed();
    if gap < st.debounce || gap < st.pacing {
        return;
    }

    if (st.target.is_none() || *st.dirty)
        && (st.target.is_none() || st.last_discover.elapsed() > Duration::from_secs(3))
    {
        *st.last_discover = Instant::now();
        *st.target = discover(device, st.connected);
        *st.dirty = false;
    }

    let Some(t) = *st.target else {
        return;
    };

    let pkt = lib::build_play_packet(t.dev_idx, t.haptic_idx, wf_id);
    if device.write(&pkt).is_err() {
        *st.target = None;
        return;
    }
    *st.last_play = Instant::now();
}

fn io_loop(
    device: HidDevice,
    rx: Receiver<lib::IpcMessage>,
    #[cfg(target_os = "linux")] mut sni: Option<lib::sni::SniService>,
) -> ! {
    let debounce = Duration::from_millis(debounce_ms());
    let pacing = Duration::from_millis(pacing_ms());
    let poll = poll_ms();
    let poll_interval = battery_poll_interval();

    let _ = device.write(&lib::ENABLE_NOTIFICATIONS);
    let _ = device.write(&lib::REANNOUNCE_DEVICES);

    let mut connected = [false; 7];
    let mut target: Option<Target> = None;
    let mut battery: Option<lib::battery::BatteryInfo> = None;
    let mut dirty = true;
    let mut last_play = Instant::now() - Duration::from_secs(3600);
    let mut last_discover = Instant::now() - Duration::from_secs(3600);
    let mut last_battery_poll = Instant::now() - Duration::from_secs(3600);
    let mut buf = [0u8; 64];

    loop {
        match device.read_timeout(&mut buf, poll) {
            Ok(0) => {}
            Ok(n) => {
                if let Some((dev, established)) = lib::parse_connection_notification(&buf[..n]) {
                    if (dev as usize) < connected.len() {
                        connected[dev as usize] = established;
                    }
                    if let Some(t) = target {
                        if t.dev_idx == dev && !established {
                            target = None;
                            battery = None;
                            #[cfg(target_os = "linux")]
                            if let Some(ref mut s) = sni {
                                s.update_connection(false);
                            }
                        }
                    }
                    dirty = true;
                }
            }
            Err(e) => {
                eprintln!("logid: HID read error ({e}); exiting for restart");
                std::process::exit(1);
            }
        }

        // Periodic battery poll
        if (target.is_some() || dirty) && last_battery_poll.elapsed() >= poll_interval {
            if target.is_none() || dirty {
                target = discover(&device, &mut connected);
                dirty = false;
            }
            if let Some(t) = target {
                battery = read_battery_status(&device, t, &mut connected);
                #[cfg(target_os = "linux")]
                if let Some(ref mut s) = sni {
                    s.update_connection(true);
                    s.update_battery(battery);
                }
            }
            last_battery_poll = Instant::now();
        }

        // Service IPC messages
        loop {
            match rx.try_recv() {
                Ok(lib::IpcMessage::Play(wf_id)) => {
                    let mut st = PlayState {
                        connected: &mut connected,
                        target: &mut target,
                        dirty: &mut dirty,
                        last_play: &mut last_play,
                        last_discover: &mut last_discover,
                        debounce,
                        pacing,
                    };
                    handle_play(wf_id, &device, &mut st);
                }
                Ok(lib::IpcMessage::QueryBattery(reply_tx)) => {
                    let _ = reply_tx.send(battery);
                }
                Ok(lib::IpcMessage::QueryStatus(reply_tx)) => {
                    let status = lib::DaemonStatus {
                        running: true,
                        device_connected: target.is_some(),
                        device_slot: target.map(|t| t.dev_idx),
                        haptic_index: target.map(|t| t.haptic_idx),
                        battery,
                    };
                    let _ = reply_tx.send(status);
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => std::process::exit(0),
            }
        }
    }
}

fn open_hidpp(api: &mut HidApi) -> HidDevice {
    loop {
        let path = api
            .device_list()
            .find(|d| {
                d.vendor_id() == lib::BOLT_VID
                    && d.product_id() == lib::BOLT_PID
                    && (d.interface_number() == lib::HIDPP_INTERFACE
                        || d.usage_page() == lib::HIDPP_USAGE_PAGE)
            })
            .map(|d| d.path().to_owned());

        if let Some(path) = path {
            match api.open_path(&path) {
                Ok(device) => {
                    eprintln!("logid: opened {}", path.to_string_lossy());
                    return device;
                }
                Err(e) => {
                    eprintln!(
                        "logid: open {} failed ({e}); retrying",
                        path.to_string_lossy()
                    )
                }
            }
        }
        thread::sleep(Duration::from_secs(2));
        let _ = api.refresh_devices();
    }
}

pub fn main() -> ExitCode {
    let server = match lib::IpcServer::bind() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("logid: IPC bind failed ({e})");
            return ExitCode::from(1);
        }
    };
    eprintln!("logid: listening on {}", server.endpoint());

    let (tx, rx) = mpsc::channel::<lib::IpcMessage>();

    // IPC Accept Thread
    thread::spawn(move || loop {
        match server.accept() {
            Ok((mut stream, line)) => {
                let trimmed = line.trim();
                let upper = trimmed.to_uppercase();
                if let Some(wf_id) = lib::waveform_id(&upper) {
                    let _ = tx.send(lib::IpcMessage::Play(wf_id));
                } else if let Some(rest) = upper.strip_prefix("HAPTIC ") {
                    if let Some(wf_id) = lib::waveform_id(rest.trim()) {
                        let _ = tx.send(lib::IpcMessage::Play(wf_id));
                    }
                } else if upper == "BATTERY" || upper == "GET_BATTERY" {
                    let (reply_tx, reply_rx) = mpsc::channel();
                    if tx.send(lib::IpcMessage::QueryBattery(reply_tx)).is_ok() {
                        if let Ok(info) = reply_rx.recv_timeout(Duration::from_millis(1500)) {
                            let json = serde_json::to_string(&info).unwrap_or_default();
                            let _ = writeln!(stream, "{json}");
                        }
                    }
                } else if upper == "STATUS" || upper == "GET_STATUS" {
                    let (reply_tx, reply_rx) = mpsc::channel();
                    if tx.send(lib::IpcMessage::QueryStatus(reply_tx)).is_ok() {
                        if let Ok(status) = reply_rx.recv_timeout(Duration::from_millis(1500)) {
                            let json = serde_json::to_string(&status).unwrap_or_default();
                            let _ = writeln!(stream, "{json}");
                        }
                    }
                } else if !upper.is_empty() {
                    let _ = writeln!(stream, "ERROR: unknown command");
                }
            }
            Err(e) => {
                eprintln!("logid: accept error ({e})");
                thread::sleep(Duration::from_millis(200));
            }
        }
    });

    #[cfg(target_os = "linux")]
    let sni_service = {
        let state = Arc::new(Mutex::new(lib::sni::SniState::default()));
        match lib::sni::SniService::start(state) {
            Ok(s) => {
                eprintln!("logid: D-Bus StatusNotifierItem registered");
                Some(s)
            }
            Err(e) => {
                eprintln!("logid: D-Bus StatusNotifierItem unavailable ({e})");
                None
            }
        }
    };

    let mut api = match HidApi::new() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("logid: hidapi init failed ({e})");
            return ExitCode::from(1);
        }
    };
    let device = open_hidpp(&mut api);

    #[cfg(target_os = "linux")]
    io_loop(device, rx, sni_service);
    #[cfg(not(target_os = "linux"))]
    io_loop(device, rx);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remaining_ms_calculates_correct_delta() {
        let deadline = Instant::now() + Duration::from_millis(500);
        let rem = remaining_ms(deadline);
        assert!(rem.is_some());
        assert!(rem.unwrap() > 0 && rem.unwrap() <= 500);

        let past = Instant::now() - Duration::from_millis(10);
        assert_eq!(remaining_ms(past), None);
    }

    #[test]
    fn target_struct_holds_battery_feature() {
        let target = Target {
            dev_idx: 1,
            haptic_idx: 4,
            battery_feature: Some(BatteryFeatureKind::LevelStatus1000(5)),
        };
        assert_eq!(target.dev_idx, 1);
        assert_eq!(target.haptic_idx, 4);
        assert_eq!(
            target.battery_feature,
            Some(BatteryFeatureKind::LevelStatus1000(5))
        );
    }
}
