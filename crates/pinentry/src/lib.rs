//! A bounded card-aware Assuan proxy. Native persistence is supplied by the caller.

mod protocol;
mod request;

pub use protocol::{ProxyError, serve, serve_with_fallback};
pub use request::{CardId, InvalidCardId};
use zeroize::Zeroizing;

pub type Secret = Zeroizing<Vec<u8>>;

/// Store failures deliberately carry no backend diagnostic or record value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoreError;

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("native PIN store failed")
    }
}
impl std::error::Error for StoreError {}

pub trait PinStore {
    /// Only `Ok(None)` denotes an absent entry.
    fn get(&mut self, card: &CardId) -> Result<Option<Secret>, StoreError>;
    fn set(&mut self, card: &CardId, value: &[u8]) -> Result<(), StoreError>;
    /// Deleting an absent entry succeeds.
    fn delete(&mut self, card: &CardId) -> Result<(), StoreError>;
}
