//! NuPhy Gem80 host RGB daemon and client library.

pub mod client;
pub mod compositor;
pub mod config;
pub mod paths;
pub mod server;
pub mod single_instance;
pub mod sync;
pub mod wire;

#[cfg(feature = "daemon")]
pub mod device;
#[cfg(feature = "daemon")]
pub mod device_state;
#[cfg(feature = "daemon")]
pub mod render;
