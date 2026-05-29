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

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!(
            "Usage: {} <WAVEFORM>",
            args.first().map(String::as_str).unwrap_or("mxm4-haptic")
        );
        return ExitCode::from(2);
    }

    let name = args[1].to_uppercase();
    if mxm4_haptic::waveform_id(&name).is_none() {
        eprintln!("Unknown waveform: {}", args[1]);
        eprintln!("Valid: {}", mxm4_haptic::waveform_names().join(", "));
        return ExitCode::from(2);
    }

    match mxm4_haptic::send_command(&name) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("mxm4-haptic: cannot reach mxm4-hapticd ({e}); is the daemon running?");
            ExitCode::from(1)
        }
    }
}
