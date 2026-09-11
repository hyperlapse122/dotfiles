//! Runtime path resolution for sockets, lockfiles, and configuration files.

use std::path::{Path, PathBuf};

/// Default AF_UNIX socket file name.
pub const DEFAULT_SOCKET_NAME: &str = "gem80-rgb.sock";

/// Default advisory single-instance lock file name.
pub const DEFAULT_LOCK_NAME: &str = "gem80-rgb.lock";

/// Default application configuration directory name.
pub const CONFIG_DIR_NAME: &str = "gem80-rgb";

/// Default configuration file name.
pub const CONFIG_FILE_NAME: &str = "config.toml";

/// Base runtime directory resolver ($XDG_RUNTIME_DIR -> $TMPDIR -> /tmp).
///
/// Follows the resolution sequence from `crates/mxm4-haptic/src/lib.rs:63-96`.
pub fn runtime_dir() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .or_else(|| std::env::var("TMPDIR").ok().filter(|d| !d.is_empty()))
        .unwrap_or_else(|| "/tmp".to_string());
    PathBuf::from(dir.trim_end_matches('/'))
}

/// Primary AF_UNIX socket path ($RUNTIME_DIR/gem80-rgb.sock).
pub fn socket_path() -> PathBuf {
    runtime_dir().join(DEFAULT_SOCKET_NAME)
}

/// Advisory single-instance lockfile path ($RUNTIME_DIR/gem80-rgb.lock).
pub fn lock_path() -> PathBuf {
    runtime_dir().join(DEFAULT_LOCK_NAME)
}

/// The lockfile that guards the daemon serving `socket_path`.
///
/// The lock is derived from the socket rather than resolved on its own, so a
/// second daemon pointed at the same socket always contends for the same lock
/// (R22, KTD4). Two independent paths would let it take a different lock, delete
/// the running daemon's socket and open the same HID node (R1).
///
/// For the default socket this is exactly [`lock_path`].
pub fn lock_path_for_socket(socket_path: impl AsRef<Path>) -> PathBuf {
    let socket_path = socket_path.as_ref();
    let dir = socket_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .map(Path::to_path_buf)
        .unwrap_or_else(runtime_dir);
    let name = socket_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(DEFAULT_SOCKET_NAME);
    let stem = name.strip_suffix(".sock").unwrap_or(name);
    dir.join(format!("{stem}.lock"))
}

/// Default user config directory ($XDG_CONFIG_HOME/gem80-rgb or ~/.config/gem80-rgb).
pub fn default_config_dir() -> Option<PathBuf> {
    if let Some(config_home) = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.is_empty())
    {
        Some(PathBuf::from(config_home.trim_end_matches('/')).join(CONFIG_DIR_NAME))
    } else if let Some(home) = std::env::var("HOME").ok().filter(|s| !s.is_empty()) {
        Some(
            PathBuf::from(home.trim_end_matches('/'))
                .join(".config")
                .join(CONFIG_DIR_NAME),
        )
    } else {
        None
    }
}

/// Default configuration file path ($XDG_CONFIG_HOME/gem80-rgb/config.toml or ~/.config/gem80-rgb/config.toml).
pub fn default_config_path() -> Option<PathBuf> {
    default_config_dir().map(|d| d.join(CONFIG_FILE_NAME))
}

#[cfg(test)]
pub(crate) static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The ambient temp root, snapshotted once before any test can change it.
///
/// The tests below set `TMPDIR` to values that do not exist to check resolution,
/// and the process environment is shared with every other test running at the same
/// time. A sibling test that asked `std::env::temp_dir()` mid-window would be handed
/// `/var/tmp_custom` and fail to create its directory. Every test that needs a temp
/// root goes through this instead.
#[cfg(test)]
pub(crate) fn ambient_temp_dir() -> &'static std::path::Path {
    static AMBIENT: std::sync::LazyLock<PathBuf> = std::sync::LazyLock::new(std::env::temp_dir);
    AMBIENT.as_path()
}

#[cfg(test)]
pub(crate) struct EnvGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
    vars: Vec<(&'static str, Option<String>)>,
}

#[cfg(test)]
impl EnvGuard {
    pub fn new(keys: &[&'static str]) -> Self {
        use crate::sync::MutexExt;
        // Resolve the real temp root before this guard can replace `TMPDIR` with a
        // path that does not exist.
        let _ = ambient_temp_dir();
        let lock = ENV_LOCK.lock_unpoisoned();
        let vars = keys.iter().map(|&k| (k, std::env::var(k).ok())).collect();
        Self { _lock: lock, vars }
    }

    pub fn set(&self, key: &str, val: &str) {
        unsafe {
            std::env::set_var(key, val);
        }
    }

    pub fn remove(&self, key: &str) {
        unsafe {
            std::env::remove_var(key);
        }
    }
}

#[cfg(test)]
impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, orig) in &self.vars {
            unsafe {
                match orig {
                    Some(v) => std::env::set_var(key, v),
                    None => std::env::remove_var(key),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_socket_and_lock_path_resolution() {
        let guard = EnvGuard::new(&["XDG_RUNTIME_DIR", "TMPDIR"]);

        // 1. XDG_RUNTIME_DIR present with trailing slash
        guard.set("XDG_RUNTIME_DIR", "/run/user/1000/");
        guard.remove("TMPDIR");
        assert_eq!(runtime_dir(), PathBuf::from("/run/user/1000"));
        assert_eq!(
            socket_path(),
            PathBuf::from("/run/user/1000/gem80-rgb.sock")
        );
        assert_eq!(lock_path(), PathBuf::from("/run/user/1000/gem80-rgb.lock"));

        // 2. XDG_RUNTIME_DIR unset, TMPDIR present
        guard.remove("XDG_RUNTIME_DIR");
        guard.set("TMPDIR", "/var/tmp_custom/");
        assert_eq!(runtime_dir(), PathBuf::from("/var/tmp_custom"));
        assert_eq!(
            socket_path(),
            PathBuf::from("/var/tmp_custom/gem80-rgb.sock")
        );
        assert_eq!(lock_path(), PathBuf::from("/var/tmp_custom/gem80-rgb.lock"));

        // 3. Both unset -> fallback to /tmp
        guard.remove("XDG_RUNTIME_DIR");
        guard.remove("TMPDIR");
        assert_eq!(runtime_dir(), PathBuf::from("/tmp"));
        assert_eq!(socket_path(), PathBuf::from("/tmp/gem80-rgb.sock"));
        assert_eq!(lock_path(), PathBuf::from("/tmp/gem80-rgb.lock"));
    }

    /// Test scenario: 소켓 경로를 바꾸면 락도 같은 디렉터리에서 그에 맞춰 움직인다 (B1, R22).
    #[test]
    fn test_lock_path_follows_the_socket_path() {
        let guard = EnvGuard::new(&["XDG_RUNTIME_DIR", "TMPDIR"]);
        guard.set("XDG_RUNTIME_DIR", "/run/user/1000");
        guard.remove("TMPDIR");

        // The default socket resolves to the documented default lock.
        assert_eq!(lock_path_for_socket(socket_path()), lock_path());

        // A socket somewhere else takes its lock with it.
        assert_eq!(
            lock_path_for_socket("/tmp/session-a/gem80-rgb.sock"),
            PathBuf::from("/tmp/session-a/gem80-rgb.lock")
        );

        // Two sockets in one directory contend for two different locks, and each
        // pair stays together.
        assert_eq!(
            lock_path_for_socket("/run/user/1000/second.sock"),
            PathBuf::from("/run/user/1000/second.lock")
        );
        assert_ne!(
            lock_path_for_socket("/run/user/1000/second.sock"),
            lock_path_for_socket(socket_path())
        );

        // A bare file name falls back to the runtime directory.
        assert_eq!(
            lock_path_for_socket("gem80-rgb.sock"),
            PathBuf::from("/run/user/1000/gem80-rgb.lock")
        );

        // A name without the conventional suffix keeps it and appends the lock one.
        assert_eq!(
            lock_path_for_socket("/tmp/plain"),
            PathBuf::from("/tmp/plain.lock")
        );
    }

    #[test]
    fn test_config_path_resolution() {
        let guard = EnvGuard::new(&["XDG_CONFIG_HOME", "HOME"]);

        // 1. XDG_CONFIG_HOME present
        guard.set("XDG_CONFIG_HOME", "/home/testuser/.custom_config/");
        guard.remove("HOME");
        assert_eq!(
            default_config_path(),
            Some(PathBuf::from(
                "/home/testuser/.custom_config/gem80-rgb/config.toml"
            ))
        );

        // 2. XDG_CONFIG_HOME unset, HOME present
        guard.remove("XDG_CONFIG_HOME");
        guard.set("HOME", "/home/testuser/");
        assert_eq!(
            default_config_path(),
            Some(PathBuf::from(
                "/home/testuser/.config/gem80-rgb/config.toml"
            ))
        );

        // 3. Both unset -> None
        guard.remove("XDG_CONFIG_HOME");
        guard.remove("HOME");
        assert_eq!(default_config_path(), None);
    }
}
