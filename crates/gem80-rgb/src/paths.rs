//! Runtime path resolution for sockets, lockfiles, and configuration files.

use std::path::PathBuf;

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

#[cfg(test)]
pub(crate) struct EnvGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
    vars: Vec<(&'static str, Option<String>)>,
}

#[cfg(test)]
impl EnvGuard {
    pub fn new(keys: &[&'static str]) -> Self {
        let lock = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
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
