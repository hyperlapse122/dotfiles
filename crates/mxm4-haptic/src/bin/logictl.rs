//! logictl — Headless Logitech device control CLI.
//!
//! Controls Logitech devices via the logid daemon:
//! - logictl battery [--json]
//! - logictl haptic <WAVEFORM>
//! - logictl status [--json]

use std::process::ExitCode;

fn usage_spec() -> String {
    let choices: String = mxm4_haptic::waveform_names()
        .iter()
        .map(|n| format!(" \"{n}\""))
        .collect();
    format!(
        "name \"logictl\"\n\
         bin \"logictl\"\n\
         version \"{ver}\"\n\
         about \"Headless Logitech device management CLI\"\n\
         cmd \"battery\" help=\"Query device battery percentage and status\" {{\n\
           flag \"--json\" help=\"Output as JSON\"\n\
         }}\n\
         cmd \"haptic\" help=\"Trigger MX Master 4 haptic waveform\" {{\n\
           arg \"<waveform>\" help=\"Waveform to play\" {{\n  choices{choices}\n}}\n\
         }}\n\
         cmd \"status\" help=\"Inspect daemon and connected device status\" {{\n\
           flag \"--json\" help=\"Output as JSON\"\n\
         }}\n",
        ver = env!("CARGO_PKG_VERSION"),
    )
}

fn print_help() {
    println!(
        "logictl {} — Headless Logitech device management CLI",
        env!("CARGO_PKG_VERSION")
    );
    println!();
    println!("Usage: logictl <COMMAND>");
    println!();
    println!("Commands:");
    println!("  battery [--json]     Query mouse battery percentage and charging state");
    println!("  haptic <WAVEFORM>    Trigger MX Master 4 haptic vibration pulse");
    println!("  status [--json]      Inspect logid daemon and device connection status");
    println!();
    println!("Options:");
    println!("  -h, --help           Print help");
    println!("  -V, --version        Print version");
    println!("  --usage              Emit usage KDL specification");
}

fn handle_battery(args: &[String]) -> ExitCode {
    let json_output = args.iter().any(|a| a == "--json");
    match mxm4_haptic::query_battery() {
        Ok(Some(info)) => {
            if json_output {
                if let Ok(json) = serde_json::to_string_pretty(&info) {
                    println!("{json}");
                }
            } else {
                println!("Battery: {}% ({})", info.percentage, info.status);
            }
            ExitCode::SUCCESS
        }
        Ok(None) => {
            if json_output {
                println!("null");
            } else {
                println!("No battery status available (device not connected or polling)");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("logictl: cannot reach logid daemon ({e}); is the daemon running?");
            ExitCode::from(1)
        }
    }
}

fn handle_haptic(args: &[String]) -> ExitCode {
    let Some(arg) = args.first() else {
        eprintln!("Error: missing <WAVEFORM> argument");
        eprintln!("Valid: {}", mxm4_haptic::waveform_names().join(", "));
        return ExitCode::from(2);
    };

    let name = arg.to_uppercase();
    if mxm4_haptic::waveform_id(&name).is_none() {
        eprintln!("Unknown waveform: {arg}");
        eprintln!("Valid: {}", mxm4_haptic::waveform_names().join(", "));
        return ExitCode::from(2);
    }

    match mxm4_haptic::send_command(&name) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("logictl: cannot reach logid daemon ({e}); is the daemon running?");
            ExitCode::from(1)
        }
    }
}

fn handle_status(args: &[String]) -> ExitCode {
    let json_output = args.iter().any(|a| a == "--json");
    match mxm4_haptic::query_status() {
        Ok(status) => {
            if json_output {
                if let Ok(json) = serde_json::to_string_pretty(&status) {
                    println!("{json}");
                }
            } else {
                println!("Daemon: running");
                println!("Device connected: {}", status.device_connected);
                if let Some(slot) = status.device_slot {
                    println!("Bolt slot: {slot}");
                }
                if let Some(haptic) = status.haptic_index {
                    println!("Haptic feature index: {haptic}");
                }
                if let Some(b) = status.battery {
                    println!("Battery: {}% ({})", b.percentage, b.status);
                } else {
                    println!("Battery: not polled or unknown");
                }
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("logictl: cannot reach logid daemon ({e}); is the daemon running?");
            ExitCode::from(1)
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        print_help();
        return ExitCode::from(2);
    }

    match args[1].as_str() {
        "--usage" => {
            print!("{}", usage_spec());
            ExitCode::SUCCESS
        }
        "-V" | "--version" => {
            println!("logictl {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "-h" | "--help" => {
            print_help();
            ExitCode::SUCCESS
        }
        "battery" => handle_battery(&args[2..]),
        "haptic" => handle_haptic(&args[2..]),
        "status" => handle_status(&args[2..]),
        other => {
            // Check if user directly passed a waveform name without 'haptic' subcommand
            if mxm4_haptic::waveform_id(&other.to_uppercase()).is_some() {
                handle_haptic(&args[1..])
            } else {
                eprintln!("Unknown command: {other}");
                print_help();
                ExitCode::from(2)
            }
        }
    }
}
