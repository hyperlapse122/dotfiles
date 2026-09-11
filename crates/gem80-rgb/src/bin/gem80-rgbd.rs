//! Gem80 host RGB daemon.
//!
//! Assembly order is the one the plan fixes: single-instance lock, configuration,
//! socket server, render thread (U5, U6, U7). The lock comes first so a second
//! instance fails before it can touch the socket or the HID node (R22, KTD4).
//!
//! `SIGTERM` and `SIGINT` set the same flag the render thread watches. The process
//! then waits for that thread to leave direct mode, so the keyboard is back on its
//! stored effect before we exit rather than after the firmware watchdog fires
//! (R5, AE9).

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use clap::Parser;

use gem80_rgb::compositor::Compositor;
use gem80_rgb::config::Config;
use gem80_rgb::render::{self, HidDeviceSource, RenderThread};
use gem80_rgb::server::{boundary_channel, ServerConfig, SocketServer, BOUNDARY_CHANNEL_CAPACITY};
use gem80_rgb::single_instance::SingleInstanceGuard;

/// How often the main thread checks the shutdown flag while the daemon runs.
const SHUTDOWN_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Parser)]
#[command(name = "gem80-rgbd", about = "NuPhy Gem80 host RGB daemon")]
struct Args {
    /// Base layer configuration file. Defaults to the standard config path.
    #[arg(long, value_name = "PATH")]
    config: Option<PathBuf>,

    /// Socket to listen on. Defaults to the runtime directory socket.
    #[arg(long, value_name = "PATH")]
    socket: Option<PathBuf>,

    /// Lockfile enforcing single-instance exclusion. Defaults to the runtime lock.
    #[arg(long, value_name = "PATH")]
    lock: Option<PathBuf>,
}

/// Registers `SIGTERM` and `SIGINT` against one shutdown flag (R5).
fn install_signal_flags() -> std::io::Result<Arc<AtomicBool>> {
    let flag = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&flag))?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&flag))?;
    Ok(flag)
}

fn main() -> ExitCode {
    let args = Args::parse();

    // 1. Single-instance lock, before the socket and before the HID node (R22, KTD4).
    let lock_path = args.lock.unwrap_or_else(gem80_rgb::paths::lock_path);
    let guard = match SingleInstanceGuard::acquire_at(&lock_path) {
        Ok(guard) => guard,
        Err(err) => {
            eprintln!("gem80-rgbd: {err}");
            return ExitCode::FAILURE;
        }
    };

    // 2. Configuration. A missing or broken file falls back to the built-in base
    //    colour instead of stopping startup (R8, AE18).
    let (config, config_error) = match args.config {
        Some(path) => Config::load_from_path_or_default(path),
        None => Config::load_default(),
    };
    if let Some(err) = config_error {
        eprintln!("gem80-rgbd: {err}; using the built-in default base layer");
    }

    let mut compositor = Compositor::new();
    config.base.apply_to_compositor(&mut compositor);

    // 3. Socket server. It opens whether or not a keyboard is attached (R2, AE4).
    let socket_path = args.socket.unwrap_or_else(gem80_rgb::paths::socket_path);
    if let Err(err) = guard.clean_stale_socket(&socket_path) {
        eprintln!(
            "gem80-rgbd: could not remove the stale socket at {}: {err}",
            socket_path.display()
        );
        return ExitCode::FAILURE;
    }

    let (sender, receiver) = boundary_channel(BOUNDARY_CHANNEL_CAPACITY);
    let server = match SocketServer::bind(&socket_path) {
        Ok(server) => server,
        Err(err) => {
            eprintln!(
                "gem80-rgbd: could not bind {}: {err}",
                socket_path.display()
            );
            return ExitCode::FAILURE;
        }
    };
    let mut server = match server.spawn(sender, ServerConfig::default()) {
        Ok(handle) => handle,
        Err(err) => {
            eprintln!("gem80-rgbd: could not start the accept loop: {err}");
            return ExitCode::FAILURE;
        }
    };

    // 4. Render thread: sole owner of the HID device (KTD7).
    let shutdown = match install_signal_flags() {
        Ok(flag) => flag,
        Err(err) => {
            eprintln!("gem80-rgbd: could not install signal handlers: {err}");
            return ExitCode::FAILURE;
        }
    };
    let render = RenderThread::new(compositor, receiver, HidDeviceSource::new());
    let mut render = match render::spawn(render, Arc::clone(&shutdown)) {
        Ok(handle) => handle,
        Err(err) => {
            eprintln!("gem80-rgbd: could not start the render thread: {err}");
            return ExitCode::FAILURE;
        }
    };

    eprintln!("gem80-rgbd: listening on {}", socket_path.display());

    while !shutdown.load(Ordering::SeqCst) {
        std::thread::sleep(SHUTDOWN_POLL_INTERVAL);
    }

    // Join the render thread first: MODE(0) must be out before we exit (R5, AE9).
    render.shutdown();
    server.shutdown();
    drop(guard);
    eprintln!("gem80-rgbd: stopped");
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Mutex;
    use std::time::Instant;

    use gem80_rgb::compositor::Color;
    use gem80_rgb::device::protocol::{
        DeviceError, HOSTRGB_REGION_ALL, HOSTRGB_SUB_MODE, PAYLOAD_SIZE,
    };
    use gem80_rgb::device::{FakeTransport, Transport};
    use gem80_rgb::render::DeviceSource;
    use gem80_rgb::server::boundary_channel;

    #[derive(Debug, Clone)]
    struct SharedFake(Arc<Mutex<(FakeTransport, Vec<[u8; PAYLOAD_SIZE]>)>>);

    impl SharedFake {
        fn new() -> Self {
            Self(Arc::new(Mutex::new((FakeTransport::new(), Vec::new()))))
        }
    }

    impl Transport for SharedFake {
        fn write_payload(&mut self, payload: &[u8; PAYLOAD_SIZE]) -> Result<(), DeviceError> {
            let mut guard = self.0.lock().unwrap_or_else(|p| p.into_inner());
            guard.1.push(*payload);
            guard.0.write_payload(payload)
        }

        fn read_payload_timeout(
            &mut self,
            timeout_ms: u32,
        ) -> Result<[u8; PAYLOAD_SIZE], DeviceError> {
            self.0
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .0
                .read_payload_timeout(timeout_ms)
        }
    }

    struct FakeSource(SharedFake);

    impl DeviceSource for FakeSource {
        type Transport = SharedFake;

        fn is_present(&mut self) -> bool {
            true
        }

        fn open(&mut self) -> Result<Option<Self::Transport>, DeviceError> {
            Ok(Some(self.0.clone()))
        }
    }

    /// Test scenario: 실행 중인 데몬에 `SIGTERM`을 보내면 `MODE(0)`이 나간 뒤 종료한다.
    /// `SIGINT`도 같다. Covers AE9.
    ///
    /// The assembled signal flag drives the real render thread here; only the HID
    /// transport is faked, so nothing but the keyboard itself is stubbed out.
    fn assert_signal_exits_through_mode_zero(signal: i32) {
        let device = SharedFake::new();
        let (_sender, receiver) = boundary_channel(16);
        let render = RenderThread::new(
            Compositor::with_base_color(Color::rgb(11, 22, 33)),
            receiver,
            FakeSource(device.clone()),
        );

        let shutdown = install_signal_flags().expect("signal handlers must install");
        let mut handle = render::spawn(render, Arc::clone(&shutdown)).expect("render must start");

        // Wait until direct mode is actually held before signalling.
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let held = device.0.lock().unwrap_or_else(|p| p.into_inner()).0.regions;
            if held == HOSTRGB_REGION_ALL || Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            device.0.lock().unwrap_or_else(|p| p.into_inner()).0.regions,
            HOSTRGB_REGION_ALL
        );

        signal_hook::low_level::raise(signal).expect("raising the signal must succeed");

        let deadline = Instant::now() + Duration::from_secs(2);
        while !shutdown.load(Ordering::SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(
            shutdown.load(Ordering::SeqCst),
            "the signal must reach the shutdown flag"
        );

        handle.shutdown();

        let guard = device.0.lock().unwrap_or_else(|p| p.into_inner());
        assert_eq!(
            guard.0.regions, 0,
            "the firmware must be out of direct mode"
        );
        let last = guard.1.last().expect("the daemon must have written");
        assert_eq!(last[1], HOSTRGB_SUB_MODE);
        assert_eq!(last[2], 0, "MODE(0) is the last thing on the wire (R5)");
    }

    /// The two signal tests share one process-wide handler, so they run in sequence
    /// inside a single test rather than racing each other's flag.
    #[test]
    fn test_sigterm_and_sigint_exit_through_mode_zero() {
        assert_signal_exits_through_mode_zero(signal_hook::consts::SIGTERM);
        assert_signal_exits_through_mode_zero(signal_hook::consts::SIGINT);
    }
}
