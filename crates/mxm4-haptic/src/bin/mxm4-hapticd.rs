//! mxm4-hapticd — MX Master 4 haptic daemon.
//!
//! Sole owner of the Bolt receiver's HID++ session. Discovers the mouse
//! and its HAPTIC feature index natively over hidraw (no Solaar CLI, no
//! on-disk cache — device state lives only in memory), serializes haptic
//! playback with debounce + per-pulse pacing, and re-discovers when the
//! mouse disconnects/reconnects (possibly at a different receiver slot).
//!
//! Inputs: waveform names on the AF_UNIX socket from the thin client
//! (Solaar rules) and the notification bridge. Output: HID++ play reports.
//!
//! Concurrency (pure std, no poll/libc):
//!   - reader thread  : blocking-reads hidraw; routes 0x41 connection
//!                      notifications (reconnect) and Root.GetFeature
//!                      replies (discovery) into shared state.
//!   - player thread  : owns the play queue; debounces, ensures the device
//!                      is discovered, writes the play report, paces.
//!   - main thread    : the UnixListener accept loop.
//!
//! Discovery (verified against Solaar receiver.py / libratbag hidpp20.c):
//!   enable 0x41 notifications (reg 0x00) -> re-announce (reg 0x02) to seed
//!   which slots are connected -> Root.GetFeature(0x19B0) on each connected
//!   slot; the slot that returns a feature index (not ERR_INVALID_FEATURE_
//!   INDEX) IS the MX Master 4, and the returned index is its HAPTIC index.
//!   Per-slot GetFeature is NOT used as a presence probe (a sleeping slot
//!   would block the full 4 s device timeout), so only connected slots are
//!   probed. Spontaneous 0x41s thereafter drive reconnect re-discovery.
//!
//! Linux-only: hidraw + AF_UNIX. See crates/README.md.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::ExitCode;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use mxm4_haptic as lib;

/// Pacing: minimum gap held AFTER a pulse so the motor finishes the
/// waveform before the next fires (the firmware exposes no "playback
/// done" event, so this is a duration estimate, tunable via env).
fn pacing_ms() -> u64 {
    std::env::var("MXM4D_PACING_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(180)
}
/// Debounce: pulses arriving within this of the last one are dropped.
fn debounce_ms() -> u64 {
    std::env::var("MXM4D_DEBOUNCE_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(120)
}

#[derive(Clone, Copy)]
struct Target {
    dev_idx: u8,
    haptic_idx: u8,
}

#[derive(Default)]
struct Inner {
    target: Option<Target>,
    /// Topology changed (a 0x41 arrived) — re-discover before next play.
    dirty: bool,
    /// Which receiver slots (1..=6) currently report a live link.
    connected: [bool; 7],
    /// In-flight Root.GetFeature: the reader fills `resp` when a reply for
    /// `dev_idx`/`SW_ID` arrives, then notifies `cv`.
    pending: Option<Pending>,
}

struct Pending {
    dev_idx: u8,
    resp: Option<[u8; 20]>,
}

struct Shared {
    inner: Mutex<Inner>,
    cv: Condvar,
}

fn write_report(file: &File, bytes: &[u8]) -> std::io::Result<()> {
    (&*file).write_all(bytes)
}

/// Block-read every hidraw report; route connection notifications and
/// pending Root.GetFeature replies. Exits the whole process on a read
/// error (receiver unplugged) so systemd restarts us against a freshly
/// resolved hidraw node.
fn reader_loop(file: Arc<File>, shared: Arc<Shared>) -> ! {
    let mut buf = [0u8; 64];
    loop {
        let n = match (&*file).read(&mut buf) {
            Ok(0) => {
                eprintln!("mxm4-hapticd: hidraw EOF; exiting for restart");
                std::process::exit(1);
            }
            Ok(n) => n,
            Err(e) => {
                eprintln!("mxm4-hapticd: hidraw read error ({e}); exiting for restart");
                std::process::exit(1);
            }
        };
        let report = &buf[..n];

        if let Some((dev, established)) = lib::parse_connection_notification(report) {
            let mut g = shared.inner.lock().unwrap();
            if (dev as usize) < g.connected.len() {
                g.connected[dev as usize] = established;
            }
            // A target that just dropped its link is no longer valid.
            if let Some(t) = g.target {
                if t.dev_idx == dev && !established {
                    g.target = None;
                }
            }
            g.dirty = true;
            shared.cv.notify_all();
            continue;
        }

        let mut g = shared.inner.lock().unwrap();
        if let Some(p) = g.pending.as_mut() {
            if lib::classify_root_reply(report, p.dev_idx, lib::SW_ID) != lib::RootReply::NotForUs {
                let mut stored = [0u8; 20];
                let len = report.len().min(20);
                stored[..len].copy_from_slice(&report[..len]);
                p.resp = Some(stored);
                shared.cv.notify_all();
            }
        }
    }
}

/// Send Root.GetFeature(0x19B0) to `dev` and wait (≤4 s) for the reader to
/// deliver a reply. Returns the HAPTIC feature index, or None on error/
/// timeout (slot is not the MX Master 4, or is unreachable).
fn get_haptic_index(file: &File, shared: &Shared, dev: u8) -> Option<u8> {
    {
        let mut g = shared.inner.lock().unwrap();
        g.pending = Some(Pending { dev_idx: dev, resp: None });
    }
    let req = lib::build_get_feature(dev, lib::HAPTIC_FEATURE_HI, lib::HAPTIC_FEATURE_LO, lib::SW_ID);
    let _ = write_report(file, &req);

    let g = shared.inner.lock().unwrap();
    let (mut g, _timed_out) = shared
        .cv
        .wait_timeout_while(g, Duration::from_secs(4), |i| {
            i.pending.as_ref().map_or(true, |p| p.resp.is_none())
        })
        .unwrap();
    let resp = g.pending.take().and_then(|p| p.resp);
    drop(g);

    match resp {
        Some(bytes) => match lib::classify_root_reply(&bytes, dev, lib::SW_ID) {
            lib::RootReply::FeatureIndex(idx) => Some(idx),
            _ => None,
        },
        None => None,
    }
}

/// Re-announce connected devices, let the reader collect the 0x41 burst,
/// then probe each connected slot for HAPTIC. First hit wins.
fn discover(file: &File, shared: &Shared) -> Option<Target> {
    let _ = write_report(file, &lib::REANNOUNCE_DEVICES);
    thread::sleep(Duration::from_millis(600));

    let slots: Vec<u8> = {
        let g = shared.inner.lock().unwrap();
        (1u8..=6).filter(|d| g.connected[*d as usize]).collect()
    };
    for dev in slots {
        if let Some(haptic_idx) = get_haptic_index(file, shared, dev) {
            eprintln!("mxm4-hapticd: MX Master 4 at slot {dev}, HAPTIC index {haptic_idx}");
            return Some(Target { dev_idx: dev, haptic_idx });
        }
    }
    None
}

/// Drain the queue, debounce, ensure the device is known, play, pace.
fn player_loop(file: Arc<File>, shared: Arc<Shared>, rx: Receiver<u8>) {
    let pacing = Duration::from_millis(pacing_ms());
    let debounce = Duration::from_millis(debounce_ms());
    let mut last_play = Instant::now() - Duration::from_secs(3600);
    // Rate-limit failed discovery so an absent device doesn't make every
    // queued command pay the 600 ms re-announce wait.
    let mut last_discover = Instant::now() - Duration::from_secs(3600);

    while let Ok(wf_id) = rx.recv() {
        if last_play.elapsed() < debounce {
            continue;
        }

        let (need_discover, mut target) = {
            let g = shared.inner.lock().unwrap();
            (g.target.is_none() || g.dirty, g.target)
        };
        if need_discover && (target.is_none() || last_discover.elapsed() > Duration::from_secs(3)) {
            last_discover = Instant::now();
            let found = discover(&file, &shared);
            let mut g = shared.inner.lock().unwrap();
            g.target = found;
            g.dirty = false;
            target = found;
        }

        let Some(t) = target else {
            continue; // device absent; a future 0x41 will set dirty + re-discover
        };

        let pkt = lib::build_play_packet(t.dev_idx, t.haptic_idx, wf_id);
        if write_report(&file, &pkt).is_err() {
            // Write failed mid-session: drop the target so the next command
            // re-discovers. A persistently dead fd surfaces as a reader EOF.
            shared.inner.lock().unwrap().target = None;
            continue;
        }
        last_play = Instant::now();
        thread::sleep(pacing);
    }
}

fn handle_conn(stream: UnixStream, tx: &Sender<u8>) {
    let mut line = String::new();
    let mut reader = BufReader::new(stream);
    if reader.read_line(&mut line).is_err() {
        return;
    }
    let name = line.trim().to_uppercase();
    if let Some(wf_id) = lib::waveform_id(&name) {
        let _ = tx.send(wf_id);
    }
}

/// Resolve the Bolt hidraw node, retrying until the receiver is present
/// (e.g. daemon started before the dongle is plugged, or just restarted).
fn open_device() -> File {
    loop {
        if let Some(path) = lib::discover_hidraw() {
            match OpenOptions::new().read(true).write(true).open(&path) {
                Ok(f) => {
                    eprintln!("mxm4-hapticd: opened {path}");
                    return f;
                }
                Err(e) => eprintln!("mxm4-hapticd: open {path} failed ({e}); retrying"),
            }
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn main() -> ExitCode {
    let Some(sock_path) = lib::socket_path() else {
        eprintln!("mxm4-hapticd: XDG_RUNTIME_DIR unset; cannot create socket");
        return ExitCode::from(1);
    };

    let file = Arc::new(open_device());
    // Enable 0x41 notifications and seed the connected-slot set. Both are
    // idempotent receiver-register writes (safe alongside a running Solaar).
    let _ = write_report(&file, &lib::ENABLE_NOTIFICATIONS);
    let _ = write_report(&file, &lib::REANNOUNCE_DEVICES);

    let shared = Arc::new(Shared { inner: Mutex::new(Inner::default()), cv: Condvar::new() });

    {
        let (f, s) = (file.clone(), shared.clone());
        thread::spawn(move || reader_loop(f, s));
    }
    let (tx, rx) = mpsc::channel::<u8>();
    {
        let (f, s) = (file.clone(), shared.clone());
        thread::spawn(move || player_loop(f, s, rx));
    }

    // Fresh socket: remove any stale one from an unclean exit, then bind.
    let _ = std::fs::remove_file(&sock_path);
    let listener = match UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("mxm4-hapticd: bind {sock_path} failed ({e})");
            return ExitCode::from(1);
        }
    };
    eprintln!("mxm4-hapticd: listening on {sock_path}");

    for stream in listener.incoming() {
        match stream {
            Ok(s) => handle_conn(s, &tx),
            Err(e) => eprintln!("mxm4-hapticd: accept error ({e})"),
        }
    }
    ExitCode::SUCCESS
}
