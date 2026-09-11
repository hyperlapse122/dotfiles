//! Advisory lockfile guard for single-instance daemon enforcement.

use std::fs::File;
use std::path::{Path, PathBuf};

/// Errors encountered while enforcing single-instance daemon exclusivity.
#[derive(Debug, thiserror::Error)]
pub enum SingleInstanceError {
    /// Another instance of the daemon is already running and holds the advisory lock (R22, KTD4).
    #[error("another instance of gem80-rgbd is already running (lock held at {0})")]
    AlreadyRunning(PathBuf),

    /// Failed to open or create the lockfile.
    #[error("failed to create or open lockfile at {0}: {1}")]
    Io(PathBuf, #[source] std::io::Error),

    /// Advisory locking call failed unexpectedly.
    #[error("failed to acquire lock on {0}: {1}")]
    LockFailed(PathBuf, #[source] std::io::Error),
}

/// Advisory lockfile guard representing exclusive ownership of the daemon instance.
///
/// Dropping this guard releases the advisory lock in the operating system kernel.
#[derive(Debug)]
pub struct SingleInstanceGuard {
    file: File,
    path: PathBuf,
}

impl SingleInstanceGuard {
    /// Attempts to acquire the single-instance lock at the default path ($RUNTIME_DIR/gem80-rgb.lock).
    pub fn acquire() -> Result<Self, SingleInstanceError> {
        Self::acquire_at(crate::paths::lock_path())
    }

    /// Attempts to acquire a non-blocking exclusive advisory flock at the specified path.
    pub fn acquire_at(path: impl AsRef<Path>) -> Result<Self, SingleInstanceError> {
        let path = path.as_ref().to_path_buf();

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| SingleInstanceError::Io(path.clone(), e))?;
        }

        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }

        let file = options
            .open(&path)
            .map_err(|e| SingleInstanceError::Io(path.clone(), e))?;

        match rustix::fs::flock(&file, rustix::fs::FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => {
                log::debug!(
                    "Acquired single-instance advisory lock at {}",
                    path.display()
                );
                Ok(SingleInstanceGuard { file, path })
            }
            Err(rustix::io::Errno::WOULDBLOCK) => {
                log::warn!(
                    "Another instance of gem80-rgbd is already running (lock held at {})",
                    path.display()
                );
                Err(SingleInstanceError::AlreadyRunning(path))
            }
            Err(err) => {
                log::error!("Failed to lock {}: {err}", path.display());
                Err(SingleInstanceError::LockFailed(path, err.into()))
            }
        }
    }

    /// Returns the path of the lockfile held by this guard.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Cleans up a stale socket file if it exists.
    ///
    /// This method is only callable on an acquired guard. This guarantees that stale socket
    /// cleanup happens strictly AFTER acquiring the single-instance lock (Approach 5, KTD4),
    /// preventing a second instance from deleting an active daemon's socket.
    pub fn clean_stale_socket(&self, socket_path: impl AsRef<Path>) -> std::io::Result<bool> {
        let path = socket_path.as_ref();
        if path.exists() {
            log::info!("Cleaning stale socket file at {}", path.display());
            std::fs::remove_file(path)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }
}

/// Convenience free function to acquire the single-instance lock at a custom path.
pub fn acquire_at(path: impl AsRef<Path>) -> Result<SingleInstanceGuard, SingleInstanceError> {
    SingleInstanceGuard::acquire_at(path)
}

impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        let _ = rustix::fs::flock(&self.file, rustix::fs::FlockOperation::Unlock);
        log::debug!(
            "Released single-instance advisory lock at {}",
            self.path.display()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests write under the crate's own build directory rather than the ambient
    /// temp root. A shared `/tmp` is not reliably writable from a sandboxed test
    /// process, and a leftover directory from another run would collide.
    fn test_dir(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join("test-tmp")
            .join(format!("{}-{}", name, std::process::id()))
    }

    #[test]
    fn test_lock_acquisition_and_conflict() {
        let temp_dir = test_dir("gem80-lock-test-1");
        std::fs::create_dir_all(&temp_dir).unwrap();
        let lock_file = temp_dir.join("test.lock");

        // First acquire succeeds
        let guard1 = acquire_at(&lock_file).expect("first acquire must succeed");
        assert_eq!(guard1.path(), lock_file.as_path());

        // Second acquire on the same path fails with AlreadyRunning (AE12)
        let err = acquire_at(&lock_file).expect_err("second acquire must fail while guard1 held");
        match err {
            SingleInstanceError::AlreadyRunning(p) => assert_eq!(p, lock_file),
            other => panic!("expected AlreadyRunning, got {:?}", other),
        }

        drop(guard1);
        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_lock_released_on_drop() {
        let temp_dir = test_dir("gem80-lock-test-2");
        std::fs::create_dir_all(&temp_dir).unwrap();
        let lock_file = temp_dir.join("test.lock");

        let guard1 = acquire_at(&lock_file).expect("first acquire must succeed");
        drop(guard1);

        // After drop, lock is immediately available
        let guard2 = acquire_at(&lock_file).expect("second acquire after drop must succeed");
        assert_eq!(guard2.path(), lock_file.as_path());
        drop(guard2);

        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_stale_socket_cleanup_after_lock() {
        let temp_dir = test_dir("gem80-lock-test-3");
        std::fs::create_dir_all(&temp_dir).unwrap();
        let lock_file = temp_dir.join("daemon.lock");
        let socket_file = temp_dir.join("daemon.sock");

        // Daemon 1 starts and creates socket
        let guard1 = acquire_at(&lock_file).expect("daemon 1 acquire");
        std::fs::write(&socket_file, b"active_daemon_socket").unwrap();
        assert!(socket_file.exists());

        // Daemon 2 attempts to acquire lock: fails
        let err = acquire_at(&lock_file).expect_err("daemon 2 acquire fails");
        assert!(matches!(err, SingleInstanceError::AlreadyRunning(_)));

        // Verification: while Daemon 1 is running, socket file MUST NOT be deleted
        assert!(socket_file.exists());
        assert_eq!(
            std::fs::read(&socket_file).unwrap(),
            b"active_daemon_socket"
        );

        // Daemon 1 terminates abruptly (guard1 dropped, socket left behind)
        drop(guard1);
        assert!(
            socket_file.exists(),
            "stale socket remains after abrupt exit"
        );

        // Daemon 2 starts now: acquires lock successfully
        let guard2 =
            acquire_at(&lock_file).expect("daemon 2 acquire succeeds after daemon 1 exits");

        // Daemon 2 cleans stale socket file using guard
        let cleaned = guard2
            .clean_stale_socket(&socket_file)
            .expect("clean stale socket");
        assert!(cleaned);
        assert!(!socket_file.exists(), "stale socket was cleanly removed");

        // Cleaning again when file doesn't exist returns Ok(false)
        let cleaned_again = guard2
            .clean_stale_socket(&socket_file)
            .expect("clean absent socket");
        assert!(!cleaned_again);

        drop(guard2);
        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    /// Environment variable naming the lockfile the child holder must take.
    const HOLDER_LOCK_ENV: &str = "GEM80_RGB_TEST_HOLD_LOCK";

    /// The child half of `test_process_termination_releases_lock`.
    ///
    /// Ignored by default and a no-op unless the parent set the environment
    /// variable, so an ordinary `--include-ignored` run neither hangs nor locks
    /// anything. It acquires the lock, says so on stdout, and then waits to be
    /// killed: an orderly exit would release the lock through `Drop` and prove
    /// nothing about what the kernel does when a holder dies.
    #[test]
    #[ignore = "spawned by test_process_termination_releases_lock as the lock holder"]
    fn hold_lock_until_killed() {
        let Ok(lock_file) = std::env::var(HOLDER_LOCK_ENV) else {
            return;
        };
        let guard = acquire_at(&lock_file).expect("the child holder must acquire the lock");
        println!("LOCKED");
        use std::io::Write;
        std::io::stdout().flush().expect("flush the handshake");
        loop {
            std::thread::sleep(std::time::Duration::from_secs(1));
            std::hint::black_box(&guard);
        }
    }

    /// Test scenario: 락을 쥔 프로세스가 급사하면 OS가 flock을 풀어 주고, 다음 데몬이
    /// 곧바로 락을 얻는다. Covers AE12.
    ///
    /// The holder is this same test binary re-executed, not an interpreter: the
    /// fact under test belongs to the kernel, and reaching for `python3` would tie
    /// the suite to whatever the CI image happens to ship.
    #[test]
    fn test_process_termination_releases_lock() {
        use std::io::{BufRead, BufReader};
        use std::process::{Command, Stdio};

        let temp_dir = test_dir("gem80-lock-test-4");
        std::fs::create_dir_all(&temp_dir).unwrap();
        let lock_file = temp_dir.join("process.lock");

        let mut child = Command::new(std::env::current_exe().expect("locate the test binary"))
            .args([
                "--exact",
                "single_instance::tests::hold_lock_until_killed",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(HOLDER_LOCK_ENV, &lock_file)
            .stdout(Stdio::piped())
            .spawn()
            .expect("spawn the child lock holder");

        // Wait until the child actually holds the lock: testing before that would
        // prove nothing.
        let mut stdout = BufReader::new(child.stdout.take().expect("child stdout"));
        let mut line = String::new();
        loop {
            line.clear();
            let read = stdout
                .read_line(&mut line)
                .expect("read the child handshake");
            assert_ne!(read, 0, "the child exited before it took the lock");
            // The harness writes `test <name> ... ` with no newline before the
            // test's own output, so the signal lands at the end of that line.
            if line.trim_end().ends_with("LOCKED") {
                break;
            }
        }

        // While the holder lives, acquiring the same lock fails.
        let err = acquire_at(&lock_file).expect_err("must fail while the holder lives");
        assert!(matches!(err, SingleInstanceError::AlreadyRunning(_)));

        // The holder dies without unlocking anything itself.
        child.kill().expect("kill the child lock holder");
        let _ = child.wait();

        // The kernel released the flock with the process, so the next daemon starts.
        let guard = acquire_at(&lock_file).expect("must succeed once the holder is gone");
        drop(guard);

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
