mod store;

use dotfiles_pinentry::{CardId, PinStore, serve_with_fallback};
use std::{ffi::OsString, io, path::PathBuf, process::ExitCode};
use store::NativeStore;

const CONFIGURATION_ERROR: &str = "invalid or unavailable frontend configuration";
const FORGET_USAGE: &str = "expected forget <card-id> with a valid YubiKey serial";

fn fallback() -> Result<PathBuf, &'static str> {
    let path = std::env::current_exe()
        .map_err(|_| CONFIGURATION_ERROR)?
        .with_extension("json");
    let contents = std::fs::read(path).map_err(|_| CONFIGURATION_ERROR)?;
    let config: serde_json::Value =
        serde_json::from_slice(&contents).map_err(|_| CONFIGURATION_ERROR)?;
    let path = config
        .get("fallback")
        .and_then(serde_json::Value::as_str)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or(CONFIGURATION_ERROR)?;
    Ok(path)
}

fn run(arguments: &[OsString]) -> Result<(), String> {
    match arguments {
        [argument] if argument == "--help" || argument == "-h" => {
            println!(
                "dotfiles-pinentry\n\nUsage: dotfiles-pinentry [pinentry options]\n       dotfiles-pinentry forget <card-id>\n\nWith no command, serve GnuPG through the configured platform pinentry.\nForget deletes only the OpenPGP user PIN for a YubiKey serial.\nUse decimal digits or a quoted grouped serial such as \"12 345 678\"."
            );
            Ok(())
        }
        [argument] if argument == "--version" => {
            println!("dotfiles-pinentry {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        [command, rest @ ..] if command == "forget" => {
            let card = match rest {
                [serial] => serial.to_str().and_then(|s| s.parse::<CardId>().ok()),
                _ => None,
            }
            .ok_or(FORGET_USAGE)?;
            NativeStore.delete(&card).map_err(|error| error.to_string())
        }
        _ => {
            let fallback = fallback()?;
            serve_with_fallback(
                &mut io::stdin().lock(),
                &mut io::stdout().lock(),
                &fallback,
                arguments,
                &mut NativeStore,
            )
            .map_err(|error| error.to_string())
        }
    }
}

fn main() -> ExitCode {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    match run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("dotfiles-pinentry: {error}");
            ExitCode::FAILURE
        }
    }
}
