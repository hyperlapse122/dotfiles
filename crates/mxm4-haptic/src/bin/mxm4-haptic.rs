//! mxm4-haptic <WAVEFORM>
//!
//! Thin one-shot client spawned by Solaar rules (rules.yaml
//! `Execute: [mxm4-haptic, "<WAVEFORM>"]`). Validates the waveform name,
//! hands it to the mxm4-hapticd daemon over the AF_UNIX socket, and exits.
//! All device I/O, debounce, queueing and pacing live in the daemon —
//! this binary never touches hidraw.
//!
//! Exits 0 on delivery, 2 on a bad/unknown waveform, 1 when the daemon is
//! unreachable (not running). There is no direct-write fallback: the
//! daemon is the sole owner of the HID++ session and the only component
//! that knows the device's runtime slot/feature index.
//!
//! `--usage` emits the CLI spec in usage KDL (https://usage.jdx.dev) so
//! `usage generate completion` can build shell completions; the waveform
//! `choices` are generated from the WAVEFORMS table so they never drift.
//! `--version` prints the crate version (used as the completion cache key).

use std::process::ExitCode;

/// usage KDL spec for this binary, with the waveform `choices` rendered
/// from the single-source-of-truth WAVEFORMS table.
fn usage_spec() -> String {
    let choices: String = mxm4_haptic::waveform_names()
        .iter()
        .map(|n| format!(" \"{n}\""))
        .collect();
    format!(
        "name \"mxm4-haptic\"\n\
         bin \"mxm4-haptic\"\n\
         version \"{ver}\"\n\
         about \"Send an MX Master 4 haptic waveform to the mxm4-hapticd daemon\"\n\
         arg \"<waveform>\" help=\"Waveform to play\" {{\n  choices{choices}\n}}\n",
        ver = env!("CARGO_PKG_VERSION"),
    )
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("--usage") => {
            print!("{}", usage_spec());
            ExitCode::SUCCESS
        }
        Some("--version") => {
            println!("mxm4-haptic {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some(arg) if args.len() == 2 => {
            let name = arg.to_uppercase();
            if mxm4_haptic::waveform_id(&name).is_none() {
                eprintln!("Unknown waveform: {arg}");
                eprintln!("Valid: {}", mxm4_haptic::waveform_names().join(", "));
                return ExitCode::from(2);
            }
            match mxm4_haptic::send_command(&name) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!(
                        "mxm4-haptic: cannot reach mxm4-hapticd ({e}); is the daemon running?"
                    );
                    ExitCode::from(1)
                }
            }
        }
        _ => {
            eprintln!(
                "Usage: {} <WAVEFORM>",
                args.first().map(String::as_str).unwrap_or("mxm4-haptic")
            );
            ExitCode::from(2)
        }
    }
}
