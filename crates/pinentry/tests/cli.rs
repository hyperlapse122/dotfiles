use std::{
    ffi::OsStr,
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Output, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Installation(PathBuf);
impl Installation {
    fn new() -> Self {
        let executable = PathBuf::from(env!("CARGO_BIN_EXE_dotfiles-pinentry"));
        let directory = executable.parent().unwrap().join(format!(
            "dotfiles-pinentry-cli-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&directory).unwrap();
        let this = Self(directory);
        // Hardlink on the same filesystem: a writable copy can be inherited by a
        // concurrently spawned child and make exec fail with ETXTBSY on Linux.
        fs::hard_link(&executable, this.binary()).unwrap();
        this
    }

    fn binary(&self) -> PathBuf {
        self.0
            .join(format!("dotfiles-pinentry{}", std::env::consts::EXE_SUFFIX))
    }

    fn config(&self, contents: &str) {
        fs::write(self.binary().with_extension("json"), contents).unwrap();
    }

    fn run(&self, arguments: &[&str], input: &[u8]) -> Output {
        let mut child = Command::new(self.binary())
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        child.wait_with_output().unwrap()
    }
}
impl Drop for Installation {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn help_and_version_work_without_configuration() {
    let install = Installation::new();
    for argument in ["--help", "--version"] {
        let result = install.run(&[argument], b"");
        assert!(result.status.success());
        assert!(result.stderr.is_empty());
        assert!(String::from_utf8_lossy(&result.stdout).contains("dotfiles-pinentry"));
    }
    let result = install.run(&["--help"], b"");
    assert!(String::from_utf8_lossy(&result.stdout).contains("forget <card-id>"));
}

#[test]
fn usage_spec_works_without_frontend_or_store_configuration() {
    let install = Installation::new();
    install.config("{invalid frontend configuration");
    let result = install.run(&["--usage-spec"], b"");
    assert!(result.status.success());
    assert!(result.stderr.is_empty());
    let spec = String::from_utf8(result.stdout).unwrap();
    assert!(spec.contains("bin \"dotfiles-pinentry\""));
    assert!(spec.contains("forget"));
    assert!(spec.contains("card-id"));
}

#[test]
fn malformed_forget_is_rejected_before_configuration_or_storage() {
    let install = Installation::new();
    for arguments in [
        vec!["forget"],
        vec!["forget", "0"],
        vec!["forget", "synthetic-secret-do-not-print"],
        vec!["forget", "12 345"],
        vec!["forget", "12345678", "extra"],
    ] {
        let result = install.run(&arguments, b"");
        assert!(!result.status.success());
        assert!(result.stdout.is_empty());
        assert_eq!(
            String::from_utf8_lossy(&result.stderr),
            "dotfiles-pinentry: expected forget <card-id> with a valid YubiKey serial\n"
        );
    }
}

#[test]
fn startup_failures_are_secret_free_and_never_write_protocol_stdout() {
    let install = Installation::new();
    for contents in [
        None,
        Some("{synthetic-secret-do-not-print"),
        Some(r#"{"fallback": "synthetic-secret-do-not-print"}"#),
        Some(r#"{"fallback": 42}"#),
    ] {
        if let Some(contents) = contents {
            install.config(contents);
        }
        let result = install.run(&[], b"");
        assert!(!result.status.success());
        assert!(result.stdout.is_empty());
        assert_eq!(
            String::from_utf8_lossy(&result.stderr),
            "dotfiles-pinentry: invalid or unavailable frontend configuration\n"
        );
    }
}

#[test]
fn missing_or_recursive_frontend_fails_without_leaking_its_path() {
    let install = Installation::new();
    for path in [
        install.binary(),
        install.0.join("synthetic-secret-do-not-print"),
    ] {
        let encoded = path.to_string_lossy().replace('\\', "\\\\");
        install.config(&format!(r#"{{"fallback":"{encoded}"}}"#));
        let result = install.run(&[], b"");
        assert!(!result.status.success());
        assert!(result.stdout.is_empty());
        assert_eq!(
            String::from_utf8_lossy(&result.stderr),
            "dotfiles-pinentry: pinentry frontend unavailable\n"
        );
    }
}

#[test]
fn server_delegates_with_original_startup_arguments() {
    let install = Installation::new();
    let frontend = install
        .0
        .join(format!("frontend{}", std::env::consts::EXE_SUFFIX));
    let source = br#"
        use std::io::{self, BufRead, Write};
        fn main() {
            let arguments = std::env::args().skip(1).collect::<Vec<_>>();
            assert!(arguments.is_empty() || arguments == ["--display", ":7", "--ttyname", "space in name"]);
            println!("OK native ready");
            io::stdout().flush().unwrap();
            for line in io::stdin().lock().lines() {
                let line = line.unwrap();
                match line.as_str() {
                    "GETPIN" => println!("D delegated-value\nOK native"),
                    _ => println!("OK"),
                }
                io::stdout().flush().unwrap();
                if line == "BYE" { break; }
            }
        }
    "#;
    let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| OsStr::new("rustc").to_owned());
    let mut compiler = Command::new(rustc)
        .args(["--crate-name", "fake_frontend", "-o"])
        .arg(&frontend)
        .arg("-")
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    compiler.stdin.take().unwrap().write_all(source).unwrap();
    assert!(compiler.wait().unwrap().success());
    let encoded = frontend.to_string_lossy().replace('\\', "\\\\");
    install.config(&format!(r#"{{"fallback":"{encoded}"}}"#));
    for arguments in [
        &[][..],
        &["--display", ":7", "--ttyname", "space in name"][..],
    ] {
        let result = install.run(arguments, b"SETDESC Ordinary passphrase\nGETPIN\nBYE\n");
        assert!(result.status.success(), "{:?}", result.stderr);
        assert!(result.stderr.is_empty());
        assert_eq!(
            result.stdout,
            b"OK native ready\nOK\nD delegated-value\nOK native\nOK\n"
        );
    }
}
