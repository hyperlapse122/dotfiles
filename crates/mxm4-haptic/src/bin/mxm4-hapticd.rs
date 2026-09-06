//! mxm4-hapticd — Backward-compatible alias entrypoint for logid.

use std::process::ExitCode;

#[path = "logid.rs"]
mod logid;

fn main() -> ExitCode {
    logid::main()
}
