//! Shared synchronization helpers.

use std::sync::{Mutex, MutexGuard};

/// Mutex locking that keeps the guard after another thread panicked while holding the lock.
///
/// Every mutex in this crate guards data that stays consistent across a panic, so a poisoned
/// lock is recovered instead of propagated.
pub trait MutexExt<T> {
    /// Locks the mutex, taking the guard out of a poison error.
    fn lock_unpoisoned(&self) -> MutexGuard<'_, T>;
}

impl<T> MutexExt<T> for Mutex<T> {
    fn lock_unpoisoned(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(|p| p.into_inner())
    }
}
