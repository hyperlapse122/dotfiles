//! Gem80 host RGB operator CLI (U9).
//!
//! Human-operable CLI for inspecting daemon state and controlling static layers:
//! - `gem80-rgbctl status [--json]`
//! - `gem80-rgbctl layers [--json]`
//! - `gem80-rgbctl frame [--json]` (alias `dump-frame`)
//! - `gem80-rgbctl layer [--name <N>] [-z <Z>] [--color <C>] [--leds <L>] [--pixel <I:C>]` (alias `static-layer`)
//! - `gem80-rgbctl --usage`
//!
//! Enforces key architectural invariants:
//! - R19: CLI acts strictly through the daemon via AF_UNIX socket; no direct HID access or hidapi linkage.
//! - R20: Status reflects daemon device state, including incompatible firmware indication (AE14).
//! - R21: Static layer command holds connection in foreground; terminating it releases layer cleanly (R13).

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};
use serde::Serialize;

use gem80_rgb::client::{Client, ClientDeviceState, ClientError, LayerInfo};
use gem80_rgb::compositor::Color;
use gem80_rgb::config::parse_hex_color;
use gem80_rgb::wire::GEM80_TOTAL_LEDS;

/// Emits the CLI specification in usage KDL format (<https://usage.jdx.dev>).
pub fn usage_spec() -> String {
    format!(
        "name \"gem80-rgbctl\"\n\
         bin \"gem80-rgbctl\"\n\
         version \"{ver}\"\n\
         about \"NuPhy Gem80 host RGB operator CLI\"\n\
         flag \"--socket <PATH>\" help=\"Socket path to connect to\"\n\
         flag \"--usage\" help=\"Emit usage KDL specification\"\n\
         cmd \"status\" help=\"Inspect daemon and device connection status (R20)\" {{\n\
           flag \"--json\" help=\"Output status as JSON\"\n\
         }}\n\
         cmd \"layers\" help=\"List active layers on the daemon (R20)\" {{\n\
           flag \"--json\" help=\"Output layers as JSON\"\n\
         }}\n\
         cmd \"frame\" help=\"Dump current composite RGB frame (R20)\" {{\n\
           flag \"--json\" help=\"Output frame as JSON\"\n\
         }}\n\
         cmd \"layer\" help=\"Add a static layer and hold connection in foreground (R21)\" {{\n\
           flag \"--name <NAME>\" help=\"Layer name (default: static-cli)\"\n\
           flag \"-z, --z-order <Z>\" help=\"Composite z-order (default: 100)\"\n\
           flag \"--color <COLOR>\" help=\"Color to apply (#RRGGBB, R,G,B, or named color)\"\n\
           flag \"--leds <LEDS>\" help=\"Target LED indices (comma-separated, ranges, or 'all')\"\n\
           flag \"--pixel <INDEX:COLOR>\" help=\"Set individual LED pixel (can be repeated)\"\n\
           flag \"--lifetime-ms <MS>\" help=\"Optional layer lifetime in milliseconds\"\n\
           flag \"--hold-ms <MS>\" help=\"Hold connection for specified milliseconds then exit\"\n\
         }}\n",
        ver = env!("CARGO_PKG_VERSION"),
    )
}

#[derive(Debug, Parser)]
#[command(
    name = "gem80-rgbctl",
    version,
    about = "NuPhy Gem80 host RGB operator CLI"
)]
pub struct Cli {
    /// Socket path to connect to. Defaults to $RUNTIME_DIR/gem80-rgb.sock.
    #[arg(long, value_name = "PATH", global = true)]
    pub socket: Option<PathBuf>,

    /// Emit usage KDL specification.
    #[arg(long)]
    pub usage: bool,

    #[command(subcommand)]
    pub command: Option<Commands>,
}

#[derive(Debug, Subcommand, Clone, PartialEq, Eq)]
pub enum Commands {
    /// Inspect daemon and device connection status (R20).
    Status {
        /// Output status as JSON.
        #[arg(long)]
        json: bool,
    },

    /// List active layers on the daemon with registration order and z-order (R20).
    Layers {
        /// Output layers as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Dump current composite RGB frame across 101 LEDs (R20).
    #[command(alias = "dump-frame")]
    Frame {
        /// Output frame as JSON.
        #[arg(long)]
        json: bool,
    },

    /// Add a static layer and hold connection in the foreground (R21).
    #[command(alias = "static-layer")]
    Layer {
        /// Layer name.
        #[arg(long, default_value = "static-cli")]
        name: String,

        /// Composite z-order index (higher sits above lower).
        #[arg(long, short = 'z', default_value_t = 100)]
        z_order: i32,

        /// Color to apply to LEDs (#RRGGBB, R,G,B, or name e.g. red, warm-white).
        #[arg(long)]
        color: Option<String>,

        /// Target LED indices (comma-separated, ranges like 0..10 or 0-9, or 'all').
        #[arg(long)]
        leds: Option<String>,

        /// Set individual LED pixel (INDEX:COLOR). Can be repeated.
        #[arg(long = "pixel")]
        pixels: Vec<String>,

        /// Optional layer lifetime in milliseconds.
        #[arg(long = "lifetime-ms")]
        lifetime_ms: Option<u32>,

        /// Hold connection for specified milliseconds then exit cleanly (for testing/automation).
        #[arg(long = "hold-ms")]
        hold_ms: Option<u64>,
    },
}

#[derive(Debug, Serialize)]
pub struct JsonStatus {
    pub daemon: &'static str,
    pub device_state: String,
    pub incompatible_firmware: bool,
    pub layer_count: usize,
    pub layers: Vec<JsonLayerSummary>,
}

#[derive(Debug, Serialize)]
pub struct JsonLayerSummary {
    pub registration_order: usize,
    pub layer_id: u32,
    pub name: String,
    pub z_order: i32,
    pub pixel_count: usize,
    pub remaining_lifetime_ms: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct JsonPixel {
    pub led: usize,
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub hex: String,
}

/// Parses a color string from named colors, `#RRGGBB`, `RRGGBB`, or `R,G,B`.
pub fn parse_color(s: &str) -> Result<Color, String> {
    let s = s.trim();
    match s.to_ascii_lowercase().as_str() {
        "red" => return Ok(Color::rgb(255, 0, 0)),
        "green" => return Ok(Color::rgb(0, 255, 0)),
        "blue" => return Ok(Color::rgb(0, 0, 255)),
        "white" => return Ok(Color::rgb(255, 255, 255)),
        "black" | "off" => return Ok(Color::rgb(0, 0, 0)),
        "warm-white" | "warmwhite" => return Ok(Color::rgb(180, 180, 180)),
        "yellow" => return Ok(Color::rgb(255, 255, 0)),
        "cyan" => return Ok(Color::rgb(0, 255, 255)),
        "magenta" => return Ok(Color::rgb(255, 0, 255)),
        "orange" => return Ok(Color::rgb(255, 128, 0)),
        "purple" => return Ok(Color::rgb(128, 0, 255)),
        _ => {}
    }

    let hex_str = s.strip_prefix('#').unwrap_or(s);
    if hex_str.len() == 6 && hex_str.chars().all(|c| c.is_ascii_hexdigit()) {
        return parse_hex_color(hex_str);
    }

    let parts: Vec<&str> = s.split(',').map(|p| p.trim()).collect();
    if parts.len() == 3 {
        let r = parts[0]
            .parse::<u8>()
            .map_err(|e| format!("invalid red byte: {e}"))?;
        let g = parts[1]
            .parse::<u8>()
            .map_err(|e| format!("invalid green byte: {e}"))?;
        let b = parts[2]
            .parse::<u8>()
            .map_err(|e| format!("invalid blue byte: {e}"))?;
        return Ok(Color::rgb(r, g, b));
    }

    Err(format!(
        "invalid color '{s}': expected #RRGGBB, R,G,B, or named color (red, green, blue, white, warm-white, black, yellow, cyan, magenta, orange, purple)"
    ))
}

/// Parses a string of LED indices (e.g. "0..10", "0-9", "0,1,2", "all").
pub fn parse_led_range(s: &str) -> Result<Vec<usize>, String> {
    let s = s.trim();
    if s.eq_ignore_ascii_case("all") {
        return Ok((0..GEM80_TOTAL_LEDS).collect());
    }

    let mut leds = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((start_s, end_s)) = part.split_once("..") {
            let start: usize = start_s
                .parse()
                .map_err(|e| format!("invalid range start: {e}"))?;
            let end: usize = end_s
                .parse()
                .map_err(|e| format!("invalid range end: {e}"))?;
            if start >= GEM80_TOTAL_LEDS || end > GEM80_TOTAL_LEDS || start > end {
                return Err(format!(
                    "range {start}..{end} out of bounds (valid: 0..{GEM80_TOTAL_LEDS})"
                ));
            }
            leds.extend(start..end);
        } else if let Some((start_s, end_s)) = part.split_once('-') {
            let start: usize = start_s
                .parse()
                .map_err(|e| format!("invalid range start: {e}"))?;
            let end: usize = end_s
                .parse()
                .map_err(|e| format!("invalid range end: {e}"))?;
            if start >= GEM80_TOTAL_LEDS || end >= GEM80_TOTAL_LEDS || start > end {
                return Err(format!(
                    "range {start}-{end} out of bounds (valid: 0..{})",
                    GEM80_TOTAL_LEDS - 1
                ));
            }
            leds.extend(start..=end);
        } else {
            let idx: usize = part
                .parse()
                .map_err(|e| format!("invalid LED index '{part}': {e}"))?;
            if idx >= GEM80_TOTAL_LEDS {
                return Err(format!(
                    "LED index {idx} out of bounds (valid: 0..{})",
                    GEM80_TOTAL_LEDS - 1
                ));
            }
            leds.push(idx);
        }
    }
    Ok(leds)
}

/// Parses an individual pixel argument `INDEX:COLOR` (e.g. `0:#ff0000`).
pub fn parse_pixel_arg(s: &str) -> Result<(usize, Color), String> {
    let (idx_str, color_str) = s
        .split_once(':')
        .ok_or_else(|| format!("invalid pixel '{s}': expected <INDEX>:<COLOR> (e.g. 0:#ff0000)"))?;
    let idx: usize = idx_str
        .trim()
        .parse()
        .map_err(|e| format!("invalid LED index in pixel '{s}': {e}"))?;
    if idx >= GEM80_TOTAL_LEDS {
        return Err(format!(
            "LED index {idx} out of bounds (valid: 0..{})",
            GEM80_TOTAL_LEDS - 1
        ));
    }
    let color = parse_color(color_str)?;
    Ok((idx, color))
}

/// Connects to the daemon, honoring an optional socket override.
pub fn connect_client(socket_path: Option<&Path>) -> Result<Client, ClientError> {
    match socket_path {
        Some(path) => Client::connect_to(path),
        None => Client::connect(),
    }
}

/// Formats device state into name, human explanation, and incompatibility indicator (R20, AE14).
pub fn format_device_state(state: ClientDeviceState) -> (&'static str, &'static str, bool) {
    match state {
        ClientDeviceState::Incompatible => (
            "Incompatible",
            "incompatible firmware: device firmware is not a revision 2 hostrgb build",
            true,
        ),
        ClientDeviceState::DirectAll => {
            ("DirectAll", "direct mode active across all regions", false)
        }
        ClientDeviceState::Entering => ("Entering", "entering direct mode", false),
        ClientDeviceState::Probing => ("Probing", "probing device firmware protocol", false),
        ClientDeviceState::Absent => ("Absent", "no keyboard device detected", false),
        ClientDeviceState::Unspecified => ("Unspecified", "device state unspecified", false),
    }
}

/// Each layer's rank in actual registration order, by position in `layers`.
///
/// The daemon answers `GetStatus` with layers sorted by z-order, so a listing's own
/// position says nothing about when a layer was registered. Numbering by position
/// would present z-order under the name "registration order" (G4). Layer IDs are
/// handed out monotonically, so their rank is the registration order whatever order
/// the caller chose to display.
fn registration_ranks(layers: &[LayerInfo]) -> Vec<usize> {
    let mut by_id: Vec<u32> = layers.iter().map(|l| l.layer_id).collect();
    by_id.sort_unstable();
    layers
        .iter()
        .map(|l| {
            by_id
                .binary_search(&l.layer_id)
                .map(|i| i + 1)
                .unwrap_or(usize::MAX)
        })
        .collect()
}

/// Converts layers into their JSON form, numbering them by registration order.
fn json_layer_summaries(layers: &[LayerInfo]) -> Vec<JsonLayerSummary> {
    let ranks = registration_ranks(layers);
    layers
        .iter()
        .zip(ranks)
        .map(|(l, rank)| JsonLayerSummary {
            registration_order: rank,
            layer_id: l.layer_id,
            name: l.name.clone(),
            z_order: l.z_order,
            pixel_count: l.pixel_count,
            remaining_lifetime_ms: l.remaining_lifetime.map(|d| d.as_millis() as u64),
        })
        .collect()
}

/// Writes one indented text line per layer, numbered by registration order.
fn write_layer_lines(
    layers: &[LayerInfo],
    out: &mut dyn std::io::Write,
) -> Result<(), ClientError> {
    let ranks = registration_ranks(layers);
    for (layer, rank) in layers.iter().zip(ranks) {
        let lt_str = match layer.remaining_lifetime {
            Some(d) => format!("{}ms remaining", d.as_millis()),
            None => "indefinite".to_string(),
        };
        writeln!(
            out,
            "  #{}: Layer ID: {}, Name: \"{}\", Z-order: {}, Pixels: {}, Lifetime: {}",
            rank, layer.layer_id, layer.name, layer.z_order, layer.pixel_count, lt_str
        )
        .map_err(ClientError::Io)?;
    }
    Ok(())
}

/// Handles the `status` command (R20, AE14).
pub fn handle_status(
    client: &Client,
    json: bool,
    out: &mut dyn std::io::Write,
) -> Result<(), ClientError> {
    let status = client.status()?;
    let (state_name, state_desc, is_incompatible) = format_device_state(status.device_state);

    if json {
        let json_status = JsonStatus {
            daemon: "running",
            device_state: state_name.to_string(),
            incompatible_firmware: is_incompatible,
            layer_count: status.layers.len(),
            layers: json_layer_summaries(&status.layers),
        };
        let formatted = serde_json::to_string_pretty(&json_status)
            .map_err(|e| ClientError::UnexpectedResponse(e.to_string()))?;
        writeln!(out, "{formatted}").map_err(ClientError::Io)?;
    } else {
        writeln!(out, "Daemon: running").map_err(ClientError::Io)?;
        writeln!(out, "Device state: {state_name} ({state_desc})").map_err(ClientError::Io)?;
        writeln!(out, "Active layers: {}", status.layers.len()).map_err(ClientError::Io)?;
        write_layer_lines(&status.layers, out)?;
    }
    Ok(())
}

/// Handles the `layers` command (R20).
pub fn handle_layers(
    client: &Client,
    json: bool,
    out: &mut dyn std::io::Write,
) -> Result<(), ClientError> {
    let mut layers = client.layers()?;
    layers.sort_by_key(|l| l.layer_id);

    if json {
        let formatted = serde_json::to_string_pretty(&json_layer_summaries(&layers))
            .map_err(|e| ClientError::UnexpectedResponse(e.to_string()))?;
        writeln!(out, "{formatted}").map_err(ClientError::Io)?;
    } else if layers.is_empty() {
        writeln!(out, "No active layers").map_err(ClientError::Io)?;
    } else {
        writeln!(out, "Active layers ({}):", layers.len()).map_err(ClientError::Io)?;
        write_layer_lines(&layers, out)?;
    }
    Ok(())
}

/// Handles the `frame` command (R20).
pub fn handle_frame(
    client: &Client,
    json: bool,
    out: &mut dyn std::io::Write,
) -> Result<(), ClientError> {
    let frame = client.composite_frame()?;
    if json {
        let pixels: Vec<JsonPixel> = frame
            .iter()
            .enumerate()
            .map(|(i, c)| JsonPixel {
                led: i,
                r: c.r,
                g: c.g,
                b: c.b,
                hex: format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b),
            })
            .collect();
        let formatted = serde_json::to_string_pretty(&pixels)
            .map_err(|e| ClientError::UnexpectedResponse(e.to_string()))?;
        writeln!(out, "{formatted}").map_err(ClientError::Io)?;
    } else {
        writeln!(out, "Composite frame ({} LEDs):", frame.len()).map_err(ClientError::Io)?;
        for (i, c) in frame.iter().enumerate() {
            writeln!(
                out,
                "  LED {:3}: #{:02x}{:02x}{:02x} (rgb: {}, {}, {})",
                i, c.r, c.g, c.b, c.r, c.g, c.b
            )
            .map_err(ClientError::Io)?;
        }
    }
    Ok(())
}

/// Handles the `layer` command (R21).
pub fn handle_layer(
    client: &Client,
    name: String,
    z_order: i32,
    color_opt: Option<String>,
    leds_opt: Option<String>,
    pixel_args: Vec<String>,
    lifetime_ms: Option<u32>,
    hold_ms: Option<u64>,
    shutdown_override: Option<Arc<AtomicBool>>,
    out: &mut dyn std::io::Write,
    err: &mut dyn std::io::Write,
) -> ExitCode {
    let mut pixels_to_set: Vec<(usize, Color)> = Vec::new();

    if let Some(color_str) = &color_opt {
        let color = match parse_color(color_str) {
            Ok(c) => c,
            Err(e) => {
                let _ = writeln!(err, "Error: {e}");
                return ExitCode::from(2);
            }
        };

        let leds = if let Some(leds_str) = &leds_opt {
            match parse_led_range(leds_str) {
                Ok(l) => l,
                Err(e) => {
                    let _ = writeln!(err, "Error: {e}");
                    return ExitCode::from(2);
                }
            }
        } else {
            (0..GEM80_TOTAL_LEDS).collect()
        };

        for led in leds {
            pixels_to_set.push((led, color));
        }
    } else if leds_opt.is_some() {
        let _ = writeln!(err, "Error: --leds specified without --color");
        return ExitCode::from(2);
    }

    for p in &pixel_args {
        match parse_pixel_arg(p) {
            Ok((led, color)) => pixels_to_set.push((led, color)),
            Err(e) => {
                let _ = writeln!(err, "Error: {e}");
                return ExitCode::from(2);
            }
        }
    }

    if pixels_to_set.is_empty() {
        let _ = writeln!(
            err,
            "Error: no pixels specified. Provide --color <COLOR> and/or --pixel <INDEX:COLOR>"
        );
        return ExitCode::from(2);
    }

    let lifetime = lifetime_ms.map(|ms| Duration::from_millis(ms as u64));
    let handle = match client.register_layer_with_lifetime(&name, z_order, lifetime) {
        Ok(h) => h,
        Err(e) => {
            let _ = writeln!(err, "gem80-rgbctl: failed to register layer: {e}");
            return ExitCode::from(1);
        }
    };

    let layer_id = match handle.layer_id() {
        Ok(id) => id,
        Err(e) => {
            let _ = writeln!(err, "gem80-rgbctl: failed to query layer ID: {e}");
            return ExitCode::from(1);
        }
    };

    if let Err(e) = handle.set_pixels(pixels_to_set) {
        let _ = writeln!(err, "gem80-rgbctl: failed to set pixels: {e}");
        return ExitCode::from(1);
    }

    let _ = writeln!(
        out,
        "Layer registered (ID: {layer_id}, Name: \"{name}\", Z-order: {z_order})."
    );
    let _ = writeln!(
        out,
        "Holding connection in foreground. Press Ctrl+C to release layer."
    );

    if let Some(ms) = hold_ms {
        std::thread::sleep(Duration::from_millis(ms));
    } else if let Some(flag) = shutdown_override {
        while !flag.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
        }
    } else {
        let shutdown = Arc::new(AtomicBool::new(false));
        if let Err(e) =
            signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&shutdown))
        {
            let _ = writeln!(err, "Warning: failed to register SIGINT handler: {e}");
        }
        if let Err(e) =
            signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&shutdown))
        {
            let _ = writeln!(err, "Warning: failed to register SIGTERM handler: {e}");
        }
        while !shutdown.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    let _ = writeln!(out, "Releasing layer and disconnecting.");
    let _ = handle.release();
    ExitCode::SUCCESS
}

/// Dispatches parsed CLI options to command handlers.
pub fn run_cli(cli: Cli, out: &mut dyn std::io::Write, err: &mut dyn std::io::Write) -> ExitCode {
    if cli.usage {
        let _ = write!(out, "{}", usage_spec());
        return ExitCode::SUCCESS;
    }

    let Some(cmd) = cli.command else {
        let _ = writeln!(err, "Error: missing command. Run with --help for usage.");
        return ExitCode::from(2);
    };

    let client = match connect_client(cli.socket.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            let _ = writeln!(
                err,
                "gem80-rgbctl: cannot reach gem80-rgbd daemon ({e}); is the daemon running?"
            );
            return ExitCode::from(1);
        }
    };

    match cmd {
        Commands::Status { json } => match handle_status(&client, json, out) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                let _ = writeln!(err, "gem80-rgbctl: status query failed: {e}");
                ExitCode::from(1)
            }
        },
        Commands::Layers { json } => match handle_layers(&client, json, out) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                let _ = writeln!(err, "gem80-rgbctl: layers query failed: {e}");
                ExitCode::from(1)
            }
        },
        Commands::Frame { json } => match handle_frame(&client, json, out) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                let _ = writeln!(err, "gem80-rgbctl: composite frame query failed: {e}");
                ExitCode::from(1)
            }
        },
        Commands::Layer {
            name,
            z_order,
            color,
            leds,
            pixels,
            lifetime_ms,
            hold_ms,
        } => handle_layer(
            &client,
            name,
            z_order,
            color,
            leds,
            pixels,
            lifetime_ms,
            hold_ms,
            None,
            out,
            err,
        ),
    }
}

fn main() -> ExitCode {
    if std::env::args().any(|a| a == "--usage") {
        print!("{}", usage_spec());
        return ExitCode::SUCCESS;
    }

    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(e) => {
            let _ = e.print();
            return ExitCode::from(if e.use_stderr() { 2 } else { 0 });
        }
    };

    let mut stdout = std::io::stdout();
    let mut stderr = std::io::stderr();
    run_cli(cli, &mut stdout, &mut stderr)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU64;
    use std::sync::Mutex;
    use std::thread;

    use gem80_rgb::compositor::Compositor;
    use gem80_rgb::server::{
        apply_boundary_message, boundary_channel, BoundaryRecvError, ServerConfig, ServerHandle,
        SocketServer,
    };
    use gem80_rgb::wire::proto::DeviceState;

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new(prefix: &str) -> Self {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let id = COUNTER.fetch_add(1, Ordering::SeqCst);
            let path = std::env::temp_dir()
                .join(format!("gem80-ctl-{prefix}-{}-{id}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("create test temp dir");
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    struct TestServer {
        _socket_dir: TestDir,
        socket_path: PathBuf,
        server_handle: Option<ServerHandle>,
        render_stop: Arc<AtomicBool>,
        render_join: Option<thread::JoinHandle<()>>,
        _compositor: Arc<Mutex<Compositor>>,
    }

    impl TestServer {
        fn start_with_state(device_state: DeviceState) -> Self {
            let socket_dir = TestDir::new("srv");
            let socket_path = socket_dir.path().join("test.sock");

            let (sender, receiver) = boundary_channel(64);
            let compositor = Arc::new(Mutex::new(Compositor::with_base_color(Color::rgb(
                180, 180, 180,
            ))));
            let render_stop = Arc::new(AtomicBool::new(false));

            let comp_clone = Arc::clone(&compositor);
            let stop_clone = Arc::clone(&render_stop);
            let render_join = thread::spawn(move || {
                while !stop_clone.load(Ordering::SeqCst) {
                    {
                        let mut c = comp_clone.lock().expect("lock");
                        c.tick();
                    }
                    match receiver.recv_timeout(Duration::from_millis(5)) {
                        Ok(msg) => {
                            let mut c = comp_clone.lock().expect("lock");
                            apply_boundary_message(&mut c, device_state, msg);
                        }
                        Err(BoundaryRecvError::Timeout) | Err(BoundaryRecvError::Empty) => {}
                        Err(BoundaryRecvError::Disconnected) => break,
                    }
                }
            });

            let server = SocketServer::bind(&socket_path).expect("bind test server");
            let server_handle = server
                .spawn(
                    sender,
                    ServerConfig {
                        max_connections: 8,
                        response_timeout: Duration::from_secs(2),
                        ..ServerConfig::default()
                    },
                )
                .expect("spawn test server");

            Self {
                _socket_dir: socket_dir,
                socket_path,
                server_handle: Some(server_handle),
                render_stop,
                render_join: Some(render_join),
                _compositor: compositor,
            }
        }
    }

    impl Drop for TestServer {
        fn drop(&mut self) {
            self.render_stop.store(true, Ordering::SeqCst);
            if let Some(mut s) = self.server_handle.take() {
                s.shutdown();
            }
            if let Some(join) = self.render_join.take() {
                let _ = join.join();
            }
        }
    }

    /// Test scenario: 상태 명령이 데몬의 장치 상태를 그대로 보여준다.
    #[test]
    fn test_status_shows_device_state() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);
        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Status { json: false }),
        };

        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);

        assert_eq!(code, ExitCode::SUCCESS);
        let out_str = String::from_utf8(out).expect("utf8");
        assert!(
            out_str.contains("Daemon: running"),
            "status must show daemon is running"
        );
        assert!(
            out_str.contains("Device state: DirectAll"),
            "status must show device state DirectAll"
        );
    }

    /// Test scenario: 호환되지 않는 펌웨어 상태가 상태 출력에 나타난다. Covers AE14.
    #[test]
    fn test_status_shows_incompatible_firmware_covers_ae14() {
        let server = TestServer::start_with_state(DeviceState::Incompatible);

        // Test human text format
        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Status { json: false }),
        };

        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);

        assert_eq!(code, ExitCode::SUCCESS);
        let out_str = String::from_utf8(out).expect("utf8");
        assert!(
            out_str.contains("Incompatible"),
            "human status must state Incompatible"
        );
        assert!(
            out_str.contains("incompatible firmware"),
            "human status must explicitly mention 'incompatible firmware' (AE14)"
        );

        // Test JSON format
        let cli_json = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Status { json: true }),
        };

        let mut json_out = Vec::new();
        let mut json_err = Vec::new();
        let code_json = run_cli(cli_json, &mut json_out, &mut json_err);

        assert_eq!(code_json, ExitCode::SUCCESS);
        let json_str = String::from_utf8(json_out).expect("utf8");
        let v: serde_json::Value = serde_json::from_str(&json_str).expect("valid json");
        assert_eq!(v["daemon"], "running");
        assert_eq!(v["device_state"], "Incompatible");
        assert_eq!(
            v["incompatible_firmware"], true,
            "JSON status must have incompatible_firmware=true (AE14)"
        );
    }

    /// Test scenario: 레이어 목록이 등록 순서와 z 값을 보여준다.
    #[test]
    fn test_layers_shows_registration_order_and_z_order() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);
        let client = Client::connect_to(&server.socket_path).expect("connect");

        // Register layer 1: z_order = 50
        let h1 = client.register_layer("alpha", 50).expect("register alpha");
        // Register layer 2: z_order = 10
        let h2 = client.register_layer("beta", 10).expect("register beta");

        // Human output test
        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Layers { json: false }),
        };

        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);

        assert_eq!(code, ExitCode::SUCCESS);
        let out_str = String::from_utf8(out).expect("utf8");
        assert!(
            out_str.contains("Active layers (2)"),
            "layers command must show active layer count"
        );
        assert!(
            out_str.contains("#1:")
                && out_str.contains("Name: \"alpha\"")
                && out_str.contains("Z-order: 50"),
            "must show registration order 1 and z-order 50 for alpha"
        );
        assert!(
            out_str.contains("#2:")
                && out_str.contains("Name: \"beta\"")
                && out_str.contains("Z-order: 10"),
            "must show registration order 2 and z-order 10 for beta"
        );

        // JSON output test
        let cli_json = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Layers { json: true }),
        };

        let mut json_out = Vec::new();
        let mut json_err = Vec::new();
        let code_json = run_cli(cli_json, &mut json_out, &mut json_err);

        assert_eq!(code_json, ExitCode::SUCCESS);
        let json_str = String::from_utf8(json_out).expect("utf8");
        let v: serde_json::Value = serde_json::from_str(&json_str).expect("valid json");
        assert_eq!(v.as_array().unwrap().len(), 2);
        assert_eq!(v[0]["registration_order"], 1);
        assert_eq!(v[0]["name"], "alpha");
        assert_eq!(v[0]["z_order"], 50);
        assert_eq!(v[1]["registration_order"], 2);
        assert_eq!(v[1]["name"], "beta");
        assert_eq!(v[1]["z_order"], 10);

        drop(h1);
        drop(h2);
    }

    /// Test scenario: `status`는 z 순서로 정렬된 목록을 받지만, 번호는 실제 등록 순서를
    /// 나타낸다. Covers G4.
    #[test]
    fn test_status_numbers_layers_by_actual_registration_order() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);
        let client = Client::connect_to(&server.socket_path).expect("connect");

        // Registered first but sorted last by z-order, so the two orders differ.
        let h1 = client.register_layer("first", 90).expect("register first");
        let h2 = client
            .register_layer("second", 10)
            .expect("register second");

        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Status { json: true }),
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        assert_eq!(run_cli(cli, &mut out, &mut err), ExitCode::SUCCESS);

        let v: serde_json::Value =
            serde_json::from_str(&String::from_utf8(out).expect("utf8")).expect("valid json");
        let layers = v["layers"].as_array().expect("layers array");
        assert_eq!(layers.len(), 2);

        // The daemon answers in z-order, so "second" leads the listing.
        assert_eq!(layers[0]["name"], "second");
        assert_eq!(layers[1]["name"], "first");

        // The numbering must still say which was registered first.
        let ordinal = |name: &str| -> u64 {
            layers
                .iter()
                .find(|l| l["name"] == name)
                .and_then(|l| l["registration_order"].as_u64())
                .expect("registration_order")
        };
        assert_eq!(
            ordinal("first"),
            1,
            "the layer registered first must be #1, not whatever z-order put first"
        );
        assert_eq!(ordinal("second"), 2);

        // The human output carries the same numbering.
        let cli_text = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Status { json: false }),
        };
        let mut text_out = Vec::new();
        let mut text_err = Vec::new();
        assert_eq!(
            run_cli(cli_text, &mut text_out, &mut text_err),
            ExitCode::SUCCESS
        );
        let text = String::from_utf8(text_out).expect("utf8");
        assert!(
            text.contains("#1: Layer ID: 1, Name: \"first\""),
            "the text listing must number by registration order too, got:\n{text}"
        );
        assert!(text.contains("#2: Layer ID: 2, Name: \"second\""));

        drop(h1);
        drop(h2);
    }

    /// Test scenario: 합성 프레임 덤프를 보여주는 읽기 명령
    #[test]
    fn test_composite_frame_dump() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);
        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Frame { json: false }),
        };

        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);

        assert_eq!(code, ExitCode::SUCCESS);
        let out_str = String::from_utf8(out).expect("utf8");
        assert!(out_str.contains("Composite frame (101 LEDs)"));
        assert!(out_str.contains("LED   0:"));
        assert!(out_str.contains("LED 100:"));

        // JSON format
        let cli_json = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Frame { json: true }),
        };

        let mut json_out = Vec::new();
        let mut json_err = Vec::new();
        let code_json = run_cli(cli_json, &mut json_out, &mut json_err);

        assert_eq!(code_json, ExitCode::SUCCESS);
        let json_str = String::from_utf8(json_out).expect("utf8");
        let v: serde_json::Value = serde_json::from_str(&json_str).expect("valid json");
        assert_eq!(v.as_array().unwrap().len(), 101);
        assert_eq!(v[0]["led"], 0);
        assert_eq!(v[100]["led"], 100);
    }

    /// Test scenario: 데몬이 없을 때 모든 명령이 명확한 오류로 끝난다.
    #[test]
    fn test_commands_fail_clearly_when_no_daemon() {
        let non_existent_dir = TestDir::new("nodaemon");
        let fake_socket = non_existent_dir.path().join("missing.sock");

        let commands = [
            Commands::Status { json: false },
            Commands::Layers { json: false },
            Commands::Frame { json: false },
            Commands::Layer {
                name: "test".to_string(),
                z_order: 10,
                color: Some("red".to_string()),
                leds: None,
                pixels: Vec::new(),
                lifetime_ms: None,
                hold_ms: Some(10),
            },
        ];

        for cmd in commands {
            let cli = Cli {
                socket: Some(fake_socket.clone()),
                usage: false,
                command: Some(cmd),
            };

            let mut out = Vec::new();
            let mut err = Vec::new();
            let code = run_cli(cli, &mut out, &mut err);

            assert_eq!(
                code,
                ExitCode::from(1),
                "must exit with code 1 when daemon unreachable"
            );
            let err_str = String::from_utf8(err).expect("utf8");
            assert!(
                err_str.contains("cannot reach gem80-rgbd daemon"),
                "error message must clearly say daemon is unreachable: got {err_str}"
            );
            assert!(
                err_str.contains("is the daemon running?"),
                "error message must ask if daemon is running"
            );
        }
    }

    /// Test scenario: 정적 레이어 명령은 전면에서 연결을 붙잡고 있고, 중단하면 레이어가 사라진다 (R21).
    #[test]
    fn test_static_layer_holds_connection_and_removes_on_disconnect() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);

        // Run layer command with hold_ms=50
        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Layer {
                name: "test-layer".to_string(),
                z_order: 25,
                color: Some("#ff0000".to_string()),
                leds: Some("0..5".to_string()),
                pixels: vec!["10:blue".to_string()],
                lifetime_ms: None,
                hold_ms: Some(50),
            }),
        };

        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);

        assert_eq!(code, ExitCode::SUCCESS);
        let out_str = String::from_utf8(out).expect("utf8");
        assert!(out_str.contains("Layer registered (ID:"));
        assert!(out_str.contains("Holding connection in foreground"));
        assert!(out_str.contains("Releasing layer and disconnecting"));

        // After completion, the client has disconnected and released the layer.
        // Daemon compositor must have 0 active client layers (R13, R21).
        let client = Client::connect_to(&server.socket_path).expect("connect");
        let layers = client.layers().expect("layers");
        assert_eq!(
            layers.len(),
            0,
            "layer must be removed once CLI command finishes and disconnects"
        );
    }

    /// Test scenario: CLI 바이너리가 `hidapi`를 링크하지 않는다 (R19).
    ///
    /// `/proc/self/maps`만 보는 검사로는 잡히지 않는다. 이 크레이트의 `hidapi`는
    /// 정적으로 링크되므로 적재된 공유 라이브러리 목록에는 애초에 나타나지 않고,
    /// 링크되어 있을 때조차 그 검사는 통과한다. 그래서 심벌을 직접 본다.
    ///
    /// `--all-features`에서는 `daemon`이 모든 타깃에 켜져 링크가 정당하므로 제외한다.
    /// 그 구성에서 실제로 심벌이 있다는 대조군은 CI의 `rust-crate` 작업이 두 산출물을
    /// 따로 빌드해 확인한다.
    #[cfg(not(feature = "daemon"))]
    #[test]
    fn test_cli_binary_does_not_link_hidapi() {
        // The needles are assembled byte by byte at run time on purpose: written as
        // string literals they would be compiled into this very binary's read-only
        // data, and the test would find itself and fail on a clean build.
        let needle = |suffix: &[u8]| -> Vec<u8> {
            let mut name = vec![b'h', b'i', b'd', b'_'];
            name.extend_from_slice(suffix);
            name
        };
        // The symbols hidapi's C backends define. A debug build keeps its symbol
        // table, which is the configuration this test runs in.
        let symbols = [
            needle(&[b'i', b'n', b'i', b't']),
            needle(&[b'o', b'p', b'e', b'n', b'_', b'p', b'a', b't', b'h']),
            needle(&[b'w', b'r', b'i', b't', b'e']),
        ];

        let Ok(binary) = std::fs::read("/proc/self/exe") else {
            // Not Linux, or /proc is not mounted. The CI job checks the artifact.
            return;
        };
        for symbol in &symbols {
            assert!(
                !binary.windows(symbol.len()).any(|w| w == symbol.as_slice()),
                "the CLI must stay hidapi-free, but {} appears in its symbols",
                String::from_utf8_lossy(symbol)
            );
        }
    }

    #[test]
    fn test_color_parsing() {
        assert_eq!(parse_color("red").unwrap(), Color::rgb(255, 0, 0));
        assert_eq!(parse_color("green").unwrap(), Color::rgb(0, 255, 0));
        assert_eq!(parse_color("blue").unwrap(), Color::rgb(0, 0, 255));
        assert_eq!(parse_color("white").unwrap(), Color::rgb(255, 255, 255));
        assert_eq!(parse_color("black").unwrap(), Color::rgb(0, 0, 0));
        assert_eq!(parse_color("off").unwrap(), Color::rgb(0, 0, 0));
        assert_eq!(
            parse_color("warm-white").unwrap(),
            Color::rgb(180, 180, 180)
        );
        assert_eq!(parse_color("#ff8800").unwrap(), Color::rgb(255, 136, 0));
        assert_eq!(parse_color("ff8800").unwrap(), Color::rgb(255, 136, 0));
        assert_eq!(parse_color("10, 20, 30").unwrap(), Color::rgb(10, 20, 30));
        assert!(parse_color("invalid_color").is_err());
    }

    #[test]
    fn test_led_range_parsing() {
        assert_eq!(parse_led_range("all").unwrap().len(), 101);
        assert_eq!(parse_led_range("0..5").unwrap(), vec![0, 1, 2, 3, 4]);
        assert_eq!(parse_led_range("0-4").unwrap(), vec![0, 1, 2, 3, 4]);
        assert_eq!(parse_led_range("1, 3, 5").unwrap(), vec![1, 3, 5]);
        assert!(parse_led_range("105").is_err());
        assert!(parse_led_range("0..102").is_err());
    }

    #[test]
    fn test_pixel_arg_parsing() {
        let (idx, color) = parse_pixel_arg("42:red").unwrap();
        assert_eq!(idx, 42);
        assert_eq!(color, Color::rgb(255, 0, 0));

        let (idx, color) = parse_pixel_arg("0:#00ffaa").unwrap();
        assert_eq!(idx, 0);
        assert_eq!(color, Color::rgb(0, 255, 170));

        assert!(parse_pixel_arg("101:red").is_err());
        assert!(parse_pixel_arg("invalid").is_err());
    }

    #[test]
    fn test_usage_spec_output() {
        let spec = usage_spec();
        assert!(spec.contains("name \"gem80-rgbctl\""));
        assert!(spec.contains("cmd \"status\""));
        assert!(spec.contains("cmd \"layers\""));
        assert!(spec.contains("cmd \"frame\""));
        assert!(spec.contains("cmd \"layer\""));

        let cli = Cli {
            socket: None,
            usage: true,
            command: None,
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);
        assert_eq!(code, ExitCode::SUCCESS);
        let out_str = String::from_utf8(out).expect("utf8");
        assert!(out_str.contains("NuPhy Gem80 host RGB operator CLI"));
    }

    #[test]
    fn test_layer_invalid_args_exit_code_2() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);

        // Missing color and pixels
        let cli = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Layer {
                name: "test".to_string(),
                z_order: 10,
                color: None,
                leds: None,
                pixels: Vec::new(),
                lifetime_ms: None,
                hold_ms: Some(10),
            }),
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);
        assert_eq!(code, ExitCode::from(2));
        let err_str = String::from_utf8(err).expect("utf8");
        assert!(err_str.contains("no pixels specified"));

        // Invalid color
        let cli_bad_color = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Layer {
                name: "test".to_string(),
                z_order: 10,
                color: Some("notacolor".to_string()),
                leds: None,
                pixels: Vec::new(),
                lifetime_ms: None,
                hold_ms: Some(10),
            }),
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli_bad_color, &mut out, &mut err);
        assert_eq!(code, ExitCode::from(2));

        // Leds without color
        let cli_leds_no_color = Cli {
            socket: Some(server.socket_path.clone()),
            usage: false,
            command: Some(Commands::Layer {
                name: "test".to_string(),
                z_order: 10,
                color: None,
                leds: Some("0..5".to_string()),
                pixels: Vec::new(),
                lifetime_ms: None,
                hold_ms: Some(10),
            }),
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli_leds_no_color, &mut out, &mut err);
        assert_eq!(code, ExitCode::from(2));
    }

    #[test]
    fn test_missing_command_exit_code_2() {
        let cli = Cli {
            socket: None,
            usage: false,
            command: None,
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run_cli(cli, &mut out, &mut err);
        assert_eq!(code, ExitCode::from(2));
        let err_str = String::from_utf8(err).expect("utf8");
        assert!(err_str.contains("missing command"));
    }

    #[test]
    fn test_static_layer_shutdown_flag_release() {
        let server = TestServer::start_with_state(DeviceState::DirectAll);
        let client = Client::connect_to(&server.socket_path).expect("connect");

        let shutdown_flag = Arc::new(AtomicBool::new(false));
        let shutdown_clone = Arc::clone(&shutdown_flag);

        let client_clone = client.clone();
        let handle_thread = thread::spawn(move || {
            let mut out = Vec::new();
            let mut err = Vec::new();
            handle_layer(
                &client_clone,
                "flag-layer".to_string(),
                40,
                Some("green".to_string()),
                None,
                Vec::new(),
                None,
                None,
                Some(shutdown_clone),
                &mut out,
                &mut err,
            )
        });

        // Wait for layer to be registered in server
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            if client.active_layer_count() > 0 || std::time::Instant::now() >= deadline {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        let layers = client.layers().expect("layers");
        assert_eq!(layers.len(), 1);
        assert_eq!(layers[0].name, "flag-layer");

        // Signal shutdown
        shutdown_flag.store(true, Ordering::SeqCst);
        let code = handle_thread.join().expect("join");
        assert_eq!(code, ExitCode::SUCCESS);

        // After release, layer is gone
        let layers_after = client.layers().expect("layers");
        assert_eq!(layers_after.len(), 0);
    }

    #[test]
    fn test_clap_parse_aliases_and_options() {
        // dump-frame alias
        let parsed = Cli::try_parse_from(["gem80-rgbctl", "dump-frame", "--json"]).unwrap();
        assert_eq!(parsed.command, Some(Commands::Frame { json: true }));

        // static-layer alias
        let parsed = Cli::try_parse_from([
            "gem80-rgbctl",
            "--socket",
            "/tmp/custom.sock",
            "static-layer",
            "--name",
            "custom",
            "-z",
            "50",
            "--color",
            "red",
        ])
        .unwrap();
        assert_eq!(parsed.socket, Some(PathBuf::from("/tmp/custom.sock")));
        assert_eq!(
            parsed.command,
            Some(Commands::Layer {
                name: "custom".to_string(),
                z_order: 50,
                color: Some("red".to_string()),
                leds: None,
                pixels: Vec::new(),
                lifetime_ms: None,
                hold_ms: None,
            })
        );
    }
}
