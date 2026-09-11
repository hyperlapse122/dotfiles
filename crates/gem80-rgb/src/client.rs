//! Client library API and LayerHandle RAII lifecycle.
//!
//! Provides a typed, high-level client for communicating with `gem80-rgbd`.
//! Clients do not interact directly with `.proto` definitions.

use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use prost::Message;

use crate::compositor::Color;
use crate::wire::{
    proto, ClientMessage, GetStatusRequest, LayerSummary, LedColor, RegisterLayerRequest,
    RejectionReason, ReleaseLayerRequest, ServerMessage, UpdateLayerRequest,
    WireMessageDiscriminator, GEM80_TOTAL_LEDS,
};

/// Default socket I/O read timeout.
pub const DEFAULT_READ_TIMEOUT: Duration = Duration::from_millis(3000);

/// Default socket I/O write timeout.
pub const DEFAULT_WRITE_TIMEOUT: Duration = Duration::from_millis(2000);

/// Errors encountered when interacting with the daemon.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("failed to connect to daemon at {path}: {source}")]
    Connect {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("I/O error during communication with daemon: {0}")]
    Io(#[from] std::io::Error),

    #[error("wire framing error: {0}")]
    Framing(#[from] crate::wire::FramingError),

    #[error("protobuf decode error: {0}")]
    Decode(#[from] prost::DecodeError),

    #[error("daemon rejected request ({reason:?}): {message}")]
    Rejected {
        reason: RejectionReason,
        message: String,
        layer_id: Option<u32>,
    },

    #[error("unexpected response from daemon: {0}")]
    UnexpectedResponse(String),

    #[error("client is not connected to daemon")]
    NotConnected,

    #[error("layer has already been released")]
    LayerReleased,

    #[error("invalid LED index {index}: must be 0..{max}")]
    InvalidLedIndex { index: usize, max: usize },

    #[error("internal client synchronization failure: {0}")]
    LockPoisoned(String),

    #[error("daemon answered request {expected} with a response to request {actual}")]
    ResponseMismatch { expected: u64, actual: u64 },

    #[error("lifetime {0:?} is outside the 1 ms..={max} ms the wire can carry", max = u32::MAX)]
    LifetimeOutOfRange(Duration),
}

/// Turns a daemon rejection into the client's own error.
///
/// One place, so the mapping cannot drift between the six call sites that need it.
fn rejected(rejection: crate::wire::RejectionResponse) -> ClientError {
    ClientError::Rejected {
        reason: proto::RejectionReason::try_from(rejection.reason)
            .unwrap_or(RejectionReason::Unspecified),
        message: rejection.message,
        layer_id: rejection.layer_id,
    }
}

/// Converts a caller's lifetime into the wire's millisecond field (E4).
///
/// Neither boundary may be truncated: a sub-millisecond lifetime would round to
/// zero, which the daemon reads as "no lifetime" and turns into a permanent layer,
/// and anything past `u32::MAX` would wrap into a short lease or zero. Both are
/// refused outright rather than silently reinterpreted.
fn lifetime_to_millis(lifetime: Duration) -> Result<u32, ClientError> {
    let millis = lifetime.as_millis();
    if millis == 0 || millis > u128::from(u32::MAX) {
        return Err(ClientError::LifetimeOutOfRange(lifetime));
    }
    Ok(millis as u32)
}

/// High-level device connection and hardware status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ClientDeviceState {
    Unspecified,
    Absent,
    Probing,
    Incompatible,
    Entering,
    DirectAll,
}

impl From<i32> for ClientDeviceState {
    fn from(val: i32) -> Self {
        match val {
            1 => Self::Absent,
            2 => Self::Probing,
            3 => Self::Incompatible,
            4 => Self::Entering,
            5 => Self::DirectAll,
            _ => Self::Unspecified,
        }
    }
}

/// Summary of an active layer on the daemon.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayerInfo {
    pub layer_id: u32,
    pub name: String,
    pub z_order: i32,
    pub remaining_lifetime: Option<Duration>,
    pub pixel_count: usize,
}

impl From<LayerSummary> for LayerInfo {
    fn from(summary: LayerSummary) -> Self {
        Self {
            layer_id: summary.layer_id,
            name: summary.name,
            z_order: summary.z_order,
            remaining_lifetime: summary
                .remaining_lifetime_ms
                .map(|ms| Duration::from_millis(ms as u64)),
            pixel_count: summary.pixel_count as usize,
        }
    }
}

/// Status of the daemon, including device state and active layers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DaemonStatus {
    pub device_state: ClientDeviceState,
    pub layers: Vec<LayerInfo>,
    pub composite_pixels: Option<Vec<Color>>,
}

/// Internal bookkeeping for an active layer held by a [`LayerHandle`].
#[derive(Debug, Clone)]
struct LayerRegistration {
    name: String,
    z_order: i32,
    /// When this layer's lifetime runs out, if it has one.
    ///
    /// The deadline is kept rather than the original duration: a reconnect has to
    /// re-announce what is left, not start the lease again (E3, R10).
    expires_at: Option<Instant>,
    daemon_layer_id: Option<u32>,
    pixels: HashMap<u32, Color>,
}

/// Snapshot of layer state prepared for re-registration across reconnects.
#[derive(Debug)]
struct LayerReannounce {
    handle_id: u64,
    name: String,
    z_order: i32,
    lifetime_ms: Option<u32>,
    pixels: Vec<LedColor>,
}

#[derive(Debug)]
struct ClientInner {
    socket_path: PathBuf,
    stream: Option<UnixStream>,
    next_request_id: u64,
    next_handle_id: u64,
    layers: HashMap<u64, LayerRegistration>,
    read_timeout: Duration,
    write_timeout: Duration,
}

impl ClientInner {
    fn new(socket_path: PathBuf) -> Self {
        Self {
            socket_path,
            stream: None,
            next_request_id: 1,
            next_handle_id: 1,
            layers: HashMap::new(),
            read_timeout: DEFAULT_READ_TIMEOUT,
            write_timeout: DEFAULT_WRITE_TIMEOUT,
        }
    }

    fn next_request_id(&mut self) -> u64 {
        let id = self.next_request_id;
        self.next_request_id = self.next_request_id.wrapping_add(1);
        id
    }

    fn connect(&mut self) -> Result<(), ClientError> {
        let stream =
            UnixStream::connect(&self.socket_path).map_err(|source| ClientError::Connect {
                path: self.socket_path.clone(),
                source,
            })?;
        stream.set_read_timeout(Some(self.read_timeout))?;
        stream.set_write_timeout(Some(self.write_timeout))?;
        self.stream = Some(stream);
        Ok(())
    }

    fn ensure_connected(&mut self) -> Result<(), ClientError> {
        if self.stream.is_none() {
            self.reconnect_internal()?;
        }
        Ok(())
    }

    fn reconnect_internal(&mut self) -> Result<(), ClientError> {
        self.stream = None;
        self.connect()?;
        self.reregister_all_layers()?;
        Ok(())
    }

    fn reregister_all_layers(&mut self) -> Result<(), ClientError> {
        // A lease that ran out while the client was disconnected does not come
        // back: the layer would have expired on the old daemon too (E3, R10).
        let now = Instant::now();
        self.layers
            .retain(|_, reg| reg.expires_at.is_none_or(|at| at > now));

        let mut layers_to_reregister: Vec<LayerReannounce> = self
            .layers
            .iter()
            .map(|(&handle_id, reg)| {
                let pixels = reg
                    .pixels
                    .iter()
                    .map(|(&led, &color)| LedColor::from((led as usize, color)))
                    .collect();
                LayerReannounce {
                    handle_id,
                    name: reg.name.clone(),
                    z_order: reg.z_order,
                    // What is left of the lease, not what it started as: a 30 s
                    // layer reconnecting at 25 s asks for the remaining 5 s.
                    lifetime_ms: reg.expires_at.map(|at| {
                        at.saturating_duration_since(now)
                            .as_millis()
                            .clamp(1, u128::from(u32::MAX)) as u32
                    }),
                    pixels,
                }
            })
            .collect();

        // Sort by z-order, then handle_id for deterministic re-registration order
        layers_to_reregister.sort_by_key(|l| (l.z_order, l.handle_id));

        for layer in layers_to_reregister {
            let req_id = self.next_request_id();
            let req = ClientMessage {
                request_id: req_id,
                payload: Some(proto::client_message::Payload::RegisterLayer(
                    RegisterLayerRequest {
                        name: layer.name,
                        z_order: layer.z_order,
                        lifetime_ms: layer.lifetime_ms,
                        blend_mode: None,
                        opacity: None,
                        push_fps: None,
                    },
                )),
            };

            let resp = self.send_message_direct(&req)?;
            match resp.payload {
                Some(proto::server_message::Payload::RegisterLayer(reg_resp)) => {
                    let new_layer_id = reg_resp.layer_id;
                    if let Some(reg) = self.layers.get_mut(&layer.handle_id) {
                        reg.daemon_layer_id = Some(new_layer_id);
                    }

                    if !layer.pixels.is_empty() {
                        let update_req = ClientMessage {
                            request_id: self.next_request_id(),
                            payload: Some(proto::client_message::Payload::UpdateLayer(
                                UpdateLayerRequest {
                                    layer_id: new_layer_id,
                                    set_pixels: layer.pixels,
                                    retract_leds: Vec::new(),
                                },
                            )),
                        };
                        let update_resp = self.send_message_direct(&update_req)?;
                        if let Some(proto::server_message::Payload::Rejection(rej)) =
                            update_resp.payload
                        {
                            return Err(rejected(rej));
                        }
                    }
                }
                Some(proto::server_message::Payload::Rejection(rej)) => {
                    return Err(rejected(rej));
                }
                other => {
                    return Err(ClientError::UnexpectedResponse(format!("{other:?}")));
                }
            }
        }
        Ok(())
    }

    fn send_message_direct(&mut self, msg: &ClientMessage) -> Result<ServerMessage, ClientError> {
        let stream = self.stream.as_mut().ok_or(ClientError::NotConnected)?;
        let body = msg.encode_to_vec();
        crate::wire::write_frame(stream, WireMessageDiscriminator::Control, &body)?;

        let (discriminator, resp_body) = crate::wire::read_frame(stream)?;
        if discriminator != WireMessageDiscriminator::Control {
            return Err(ClientError::UnexpectedResponse(format!(
                "expected control message, got discriminator {discriminator:?}"
            )));
        }
        let server_msg = ServerMessage::decode(resp_body.as_slice())?;

        // The protocol is one answer per request on one stream, so a mismatched ID
        // means a late answer is still in the stream and everything after it would
        // be read one response out of step. The stream is no longer usable (E5).
        if server_msg.request_id != msg.request_id {
            self.stream = None;

            // Request IDs start at 1, so zero marks a notice the daemon sent on its
            // own initiative rather than an answer to anything: the connection-limit
            // rejection it writes before closing a refused connection. Reporting
            // that as a mismatch would hide why the connection went away.
            if server_msg.request_id == 0 {
                if let Some(proto::server_message::Payload::Rejection(rej)) = server_msg.payload {
                    return Err(rejected(rej));
                }
            }

            let mismatch = ClientError::ResponseMismatch {
                expected: msg.request_id,
                actual: server_msg.request_id,
            };
            log::debug!("gem80-rgb client: {mismatch}; dropping the stream");
            return Err(mismatch);
        }
        Ok(server_msg)
    }

    /// Drops the stream so the next call reconnects (R16).
    fn invalidate_stream(&mut self) {
        self.stream = None;
    }

    fn register_layer(
        &mut self,
        name: String,
        z_order: i32,
        lifetime: Option<Duration>,
    ) -> Result<u64, ClientError> {
        let lifetime_ms = lifetime.map(lifetime_to_millis).transpose()?;
        self.ensure_connected()?;
        let handle_id = self.next_handle_id;
        self.next_handle_id += 1;

        let req_id = self.next_request_id();
        let req = ClientMessage {
            request_id: req_id,
            payload: Some(proto::client_message::Payload::RegisterLayer(
                RegisterLayerRequest {
                    name: name.clone(),
                    z_order,
                    lifetime_ms,
                    blend_mode: None,
                    opacity: None,
                    push_fps: None,
                },
            )),
        };

        let resp = match self.send_message_direct(&req) {
            Ok(resp) => resp,
            Err(e @ (ClientError::Io(_) | ClientError::Framing(_))) => {
                log::debug!("gem80-rgb client: connection lost during register, reconnecting: {e}");
                self.reconnect_internal()?;
                let retry_req = ClientMessage {
                    request_id: self.next_request_id(),
                    payload: Some(proto::client_message::Payload::RegisterLayer(
                        RegisterLayerRequest {
                            name: name.clone(),
                            z_order,
                            lifetime_ms,
                            blend_mode: None,
                            opacity: None,
                            push_fps: None,
                        },
                    )),
                };
                self.send_message_direct(&retry_req)?
            }
            Err(e) => return Err(e),
        };

        match resp.payload {
            Some(proto::server_message::Payload::RegisterLayer(reg_resp)) => {
                self.layers.insert(
                    handle_id,
                    LayerRegistration {
                        name,
                        z_order,
                        expires_at: lifetime.map(|d| Instant::now() + d),
                        daemon_layer_id: Some(reg_resp.layer_id),
                        pixels: HashMap::new(),
                    },
                );
                Ok(handle_id)
            }
            Some(proto::server_message::Payload::Rejection(rej)) => Err(rejected(rej)),
            other => Err(ClientError::UnexpectedResponse(format!("{other:?}"))),
        }
    }

    fn update_layer(
        &mut self,
        handle_id: u64,
        set_pixels: Vec<(usize, Color)>,
        retract_leds: Vec<usize>,
    ) -> Result<(), ClientError> {
        for (idx, _) in &set_pixels {
            if *idx >= GEM80_TOTAL_LEDS {
                return Err(ClientError::InvalidLedIndex {
                    index: *idx,
                    max: GEM80_TOTAL_LEDS - 1,
                });
            }
        }
        for idx in &retract_leds {
            if *idx >= GEM80_TOTAL_LEDS {
                return Err(ClientError::InvalidLedIndex {
                    index: *idx,
                    max: GEM80_TOTAL_LEDS - 1,
                });
            }
        }

        let daemon_layer_id = self
            .layers
            .get(&handle_id)
            .ok_or(ClientError::LayerReleased)?
            .daemon_layer_id
            .ok_or(ClientError::NotConnected)?;

        let proto_set: Vec<LedColor> = set_pixels.iter().copied().map(LedColor::from).collect();
        let proto_retract: Vec<u32> = retract_leds.iter().map(|idx| *idx as u32).collect();

        self.send_update_layer_request(handle_id, daemon_layer_id, proto_set, proto_retract)?;

        // Only now, with the daemon's acceptance in hand. The cache is what a
        // reconnect replays, so writing a pixel the daemon rejected would reapply
        // on the next reconnect the very state the API reported as refused (E1).
        if let Some(reg) = self.layers.get_mut(&handle_id) {
            for (idx, color) in &set_pixels {
                reg.pixels.insert(*idx as u32, *color);
            }
            for idx in &retract_leds {
                reg.pixels.remove(&(*idx as u32));
            }
        }
        Ok(())
    }

    fn send_update_layer_request(
        &mut self,
        handle_id: u64,
        layer_id: u32,
        set_pixels: Vec<LedColor>,
        retract_leds: Vec<u32>,
    ) -> Result<(), ClientError> {
        self.ensure_connected()?;
        let req_id = self.next_request_id();
        let req = ClientMessage {
            request_id: req_id,
            payload: Some(proto::client_message::Payload::UpdateLayer(
                UpdateLayerRequest {
                    layer_id,
                    set_pixels,
                    retract_leds,
                },
            )),
        };

        match self.send_message_direct(&req) {
            Ok(resp) => self.handle_update_response(resp),
            Err(e @ (ClientError::Io(_) | ClientError::Framing(_))) => {
                log::debug!("gem80-rgb client: connection lost during update, reconnecting: {e}");
                self.reconnect_internal()?;
                let new_layer_id = self
                    .layers
                    .get(&handle_id)
                    .and_then(|r| r.daemon_layer_id)
                    .ok_or(ClientError::LayerReleased)?;

                // The retry reuses the pixels of the request just built, so the
                // successful path never copies them.
                let Some(proto::client_message::Payload::UpdateLayer(mut update)) = req.payload
                else {
                    return Err(e);
                };
                update.layer_id = new_layer_id;
                let retry_req = ClientMessage {
                    request_id: self.next_request_id(),
                    payload: Some(proto::client_message::Payload::UpdateLayer(update)),
                };
                let retry_resp = self.send_message_direct(&retry_req)?;
                self.handle_update_response(retry_resp)
            }
            Err(e) => Err(e),
        }
    }

    fn handle_update_response(&self, resp: ServerMessage) -> Result<(), ClientError> {
        match resp.payload {
            Some(proto::server_message::Payload::UpdateLayer(_)) => Ok(()),
            Some(proto::server_message::Payload::Rejection(rej)) => Err(rejected(rej)),
            other => Err(ClientError::UnexpectedResponse(format!("{other:?}"))),
        }
    }

    fn release_layer(&mut self, handle_id: u64) -> Result<(), ClientError> {
        let reg = match self.layers.remove(&handle_id) {
            Some(reg) => reg,
            None => return Ok(()),
        };

        let Some(daemon_layer_id) = reg.daemon_layer_id else {
            return Ok(());
        };
        if self.stream.is_none() {
            return Ok(());
        }

        let req = ClientMessage {
            request_id: self.next_request_id(),
            payload: Some(proto::client_message::Payload::ReleaseLayer(
                ReleaseLayerRequest {
                    layer_id: daemon_layer_id,
                },
            )),
        };
        match self.send_message_direct(&req) {
            Ok(resp) => match resp.payload {
                Some(proto::server_message::Payload::Rejection(rej)) => Err(rejected(rej)),
                _ => Ok(()),
            },
            // Swallowing this would leave the daemon holding a layer the client has
            // already forgotten, painting pixels nothing can retract. Dropping the
            // stream makes the next call reconnect, and the daemon releases every
            // layer of the closed connection itself (E2, R13, R16).
            Err(e @ (ClientError::Io(_) | ClientError::Framing(_))) => {
                log::debug!(
                    "gem80-rgb client: release of layer {daemon_layer_id} did not get through \
                     ({e}); dropping the stream so the daemon cleans up"
                );
                self.invalidate_stream();
                Err(e)
            }
            Err(e) => Err(e),
        }
    }

    fn get_status(
        &mut self,
        include_layers: bool,
        include_composite_frame: bool,
    ) -> Result<DaemonStatus, ClientError> {
        self.ensure_connected()?;
        let req_id = self.next_request_id();
        let req = ClientMessage {
            request_id: req_id,
            payload: Some(proto::client_message::Payload::GetStatus(
                GetStatusRequest {
                    include_layers,
                    include_composite_frame,
                },
            )),
        };

        let resp = match self.send_message_direct(&req) {
            Ok(resp) => resp,
            Err(e @ (ClientError::Io(_) | ClientError::Framing(_))) => {
                log::debug!("gem80-rgb client: connection lost during status, reconnecting: {e}");
                self.reconnect_internal()?;
                let retry_req = ClientMessage {
                    request_id: self.next_request_id(),
                    payload: Some(proto::client_message::Payload::GetStatus(
                        GetStatusRequest {
                            include_layers,
                            include_composite_frame,
                        },
                    )),
                };
                self.send_message_direct(&retry_req)?
            }
            Err(e) => return Err(e),
        };

        match resp.payload {
            Some(proto::server_message::Payload::GetStatus(status_resp)) => {
                let device_state = ClientDeviceState::from(status_resp.device_state);
                let layers = status_resp
                    .layers
                    .into_iter()
                    .map(LayerInfo::from)
                    .collect();
                let composite_pixels = if status_resp.composite_pixels.is_empty() {
                    None
                } else {
                    // A trailing partial pixel is a protocol violation, not
                    // something to discard: dropping the remainder would let a
                    // 304-byte body parse as 101 pixels and pass the count check
                    // that is supposed to catch exactly this (E6).
                    let (chunks, remainder) = status_resp.composite_pixels.as_chunks::<3>();
                    if !remainder.is_empty() {
                        return Err(ClientError::UnexpectedResponse(format!(
                            "composite frame of {} bytes is not a whole number of RGB pixels",
                            status_resp.composite_pixels.len()
                        )));
                    }
                    Some(
                        chunks
                            .iter()
                            .map(|&chunk| Color::from_bytes(chunk))
                            .collect(),
                    )
                };

                Ok(DaemonStatus {
                    device_state,
                    layers,
                    composite_pixels,
                })
            }
            Some(proto::server_message::Payload::Rejection(rej)) => Err(rejected(rej)),
            other => Err(ClientError::UnexpectedResponse(format!("{other:?}"))),
        }
    }
}

/// High-level client for the Gem80 RGB daemon.
#[derive(Debug, Clone)]
pub struct Client {
    inner: Arc<Mutex<ClientInner>>,
}

/// Locks the shared client state, turning a poisoned lock into a typed error.
fn lock_inner(inner: &Mutex<ClientInner>) -> Result<MutexGuard<'_, ClientInner>, ClientError> {
    inner
        .lock()
        .map_err(|e| ClientError::LockPoisoned(e.to_string()))
}

impl Client {
    /// Connects to the daemon using the default runtime socket path.
    pub fn connect() -> Result<Self, ClientError> {
        let path = crate::paths::socket_path();
        Self::connect_to(path)
    }

    /// Connects to the daemon at the specified socket path.
    pub fn connect_to(path: impl AsRef<Path>) -> Result<Self, ClientError> {
        let path = path.as_ref().to_path_buf();
        let mut inner = ClientInner::new(path);
        inner.connect()?;
        Ok(Self {
            inner: Arc::new(Mutex::new(inner)),
        })
    }

    /// Configures custom read and write timeouts on the client connection.
    pub fn with_timeouts(
        self,
        read_timeout: Duration,
        write_timeout: Duration,
    ) -> Result<Self, ClientError> {
        {
            let mut inner = lock_inner(&self.inner)?;
            inner.read_timeout = read_timeout;
            inner.write_timeout = write_timeout;
            if let Some(stream) = inner.stream.as_mut() {
                let _ = stream.set_read_timeout(Some(read_timeout));
                let _ = stream.set_write_timeout(Some(write_timeout));
            }
        }
        Ok(self)
    }

    /// Reconnects to the daemon and re-registers all held layers (R16).
    pub fn reconnect(&self) -> Result<(), ClientError> {
        let mut inner = lock_inner(&self.inner)?;
        inner.reconnect_internal()
    }

    /// Returns whether the client currently holds an active connection.
    pub fn is_connected(&self) -> bool {
        lock_inner(&self.inner)
            .map(|i| i.stream.is_some())
            .unwrap_or(false)
    }

    /// Returns the number of layers currently registered and held by this client.
    pub fn active_layer_count(&self) -> usize {
        lock_inner(&self.inner).map(|i| i.layers.len()).unwrap_or(0)
    }

    /// Registers a new compositing layer with indefinite lifetime (R12).
    pub fn register_layer(
        &self,
        name: impl Into<String>,
        z_order: i32,
    ) -> Result<LayerHandle, ClientError> {
        self.register_layer_with_lifetime(name, z_order, None)
    }

    /// Registers a new compositing layer with an optional lifetime duration (R10, R12).
    ///
    /// A lifetime the wire's millisecond field cannot carry is refused rather than
    /// truncated: see [`lifetime_to_millis`] (E4).
    pub fn register_layer_with_lifetime(
        &self,
        name: impl Into<String>,
        z_order: i32,
        lifetime: Option<Duration>,
    ) -> Result<LayerHandle, ClientError> {
        let name = name.into();
        let handle_id = {
            let mut inner = lock_inner(&self.inner)?;
            inner.register_layer(name, z_order, lifetime)?
        };
        Ok(LayerHandle {
            inner: Arc::clone(&self.inner),
            handle_id,
            released: false,
        })
    }

    /// Queries the full daemon status, including active layers and composite pixels.
    pub fn status(&self) -> Result<DaemonStatus, ClientError> {
        self.get_status(true, true)
    }

    /// Queries daemon status with selective layer and composite frame inclusion.
    pub fn get_status(
        &self,
        include_layers: bool,
        include_composite_frame: bool,
    ) -> Result<DaemonStatus, ClientError> {
        let mut inner = lock_inner(&self.inner)?;
        inner.get_status(include_layers, include_composite_frame)
    }

    /// Queries the list of active layers on the daemon.
    pub fn layers(&self) -> Result<Vec<LayerInfo>, ClientError> {
        let status = self.get_status(true, false)?;
        Ok(status.layers)
    }

    /// Queries the current composite frame of 101 RGB pixels from the daemon.
    pub fn composite_frame(&self) -> Result<[Color; GEM80_TOTAL_LEDS], ClientError> {
        let status = self.get_status(false, true)?;
        match status.composite_pixels {
            Some(pixels) if pixels.len() == GEM80_TOTAL_LEDS => {
                let mut arr = [Color::BLACK; GEM80_TOTAL_LEDS];
                arr.copy_from_slice(&pixels);
                Ok(arr)
            }
            _ => Err(ClientError::UnexpectedResponse(
                "composite frame missing or incorrect size".to_string(),
            )),
        }
    }
}

/// RAII handle to an active layer on the daemon.
///
/// When dropped, sends `ReleaseLayerRequest` to unregister the layer from the daemon (R15).
#[derive(Debug)]
pub struct LayerHandle {
    inner: Arc<Mutex<ClientInner>>,
    handle_id: u64,
    released: bool,
}

impl LayerHandle {
    /// Returns the daemon-assigned layer ID, if currently registered.
    pub fn layer_id(&self) -> Result<u32, ClientError> {
        if self.released {
            return Err(ClientError::LayerReleased);
        }
        let inner = lock_inner(&self.inner)?;
        inner
            .layers
            .get(&self.handle_id)
            .and_then(|r| r.daemon_layer_id)
            .ok_or(ClientError::LayerReleased)
    }

    /// Returns the name of this layer.
    pub fn name(&self) -> Result<String, ClientError> {
        if self.released {
            return Err(ClientError::LayerReleased);
        }
        let inner = lock_inner(&self.inner)?;
        inner
            .layers
            .get(&self.handle_id)
            .map(|r| r.name.clone())
            .ok_or(ClientError::LayerReleased)
    }

    /// Returns the composite z-order of this layer.
    pub fn z_order(&self) -> Result<i32, ClientError> {
        if self.released {
            return Err(ClientError::LayerReleased);
        }
        let inner = lock_inner(&self.inner)?;
        inner
            .layers
            .get(&self.handle_id)
            .map(|r| r.z_order)
            .ok_or(ClientError::LayerReleased)
    }

    /// Sets a single LED color on this layer (sparse update, R14).
    pub fn set_pixel(&self, led_index: usize, color: Color) -> Result<(), ClientError> {
        self.set_pixels([(led_index, color)])
    }

    /// Sets multiple LED colors on this layer (sparse update, R14).
    pub fn set_pixels<I>(&self, pixels: I) -> Result<(), ClientError>
    where
        I: IntoIterator<Item = (usize, Color)>,
    {
        self.update(pixels, std::iter::empty())
    }

    /// Retracts a single LED so that lower layers show through (R24).
    pub fn retract_pixel(&self, led_index: usize) -> Result<(), ClientError> {
        self.retract_pixels([led_index])
    }

    /// Retracts multiple LEDs so that lower layers show through (R24).
    pub fn retract_pixels<I>(&self, leds: I) -> Result<(), ClientError>
    where
        I: IntoIterator<Item = usize>,
    {
        self.update(std::iter::empty(), leds)
    }

    /// Atomically updates set pixels and retracted LEDs in a single request (R14, R24).
    pub fn update<P, R>(&self, set_pixels: P, retract_leds: R) -> Result<(), ClientError>
    where
        P: IntoIterator<Item = (usize, Color)>,
        R: IntoIterator<Item = usize>,
    {
        if self.released {
            return Err(ClientError::LayerReleased);
        }
        let set: Vec<(usize, Color)> = set_pixels.into_iter().collect();
        let retract: Vec<usize> = retract_leds.into_iter().collect();
        let mut inner = lock_inner(&self.inner)?;
        inner.update_layer(self.handle_id, set, retract)
    }

    /// Explicitly releases this layer immediately instead of waiting for drop.
    pub fn release(mut self) -> Result<(), ClientError> {
        if self.released {
            return Err(ClientError::LayerReleased);
        }
        self.released = true;
        let mut inner = lock_inner(&self.inner)?;
        inner.release_layer(self.handle_id)
    }
}

impl Drop for LayerHandle {
    fn drop(&mut self) {
        if !self.released {
            self.released = true;
            if let Ok(mut inner) = self.inner.lock() {
                let _ = inner.release_layer(self.handle_id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread;

    use crate::compositor::Compositor;
    use crate::server::{
        apply_boundary_message, boundary_channel, BoundaryRecvError, ServerConfig, ServerHandle,
        SocketServer,
    };
    use crate::wire::proto::DeviceState;

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new(prefix: &str) -> Self {
            use std::sync::atomic::AtomicU64;
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let id = COUNTER.fetch_add(1, Ordering::SeqCst);
            // The ambient temp root, not the crate's build directory: an AF_UNIX
            // path must fit in SUN_LEN (~108 bytes), and a path under a worktree
            // checkout does not. Sibling tests that write plain files use the
            // crate directory instead, where no such limit applies. It comes from
            // the snapshot rather than `std::env::temp_dir()` because the paths
            // tests replace `TMPDIR` process-wide while these run.
            let path = crate::paths::ambient_temp_dir()
                .join(format!("gem80-{prefix}-{}-{id}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("create test temp dir");
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    struct TestServer {
        _socket_dir: TestDir,
        socket_path: PathBuf,
        server_handle: Option<ServerHandle>,
        render_stop: Arc<AtomicBool>,
        render_join: Option<thread::JoinHandle<()>>,
    }

    impl TestServer {
        fn start_with_path(socket_dir: TestDir, socket_path: PathBuf) -> Self {
            let (sender, receiver) = boundary_channel(64);
            let compositor = Arc::new(Mutex::new(Compositor::with_base_color(Color::rgb(
                10, 20, 30,
            ))));
            let render_stop = Arc::new(AtomicBool::new(false));

            let comp_clone = Arc::clone(&compositor);
            let stop_clone = Arc::clone(&render_stop);
            let render_join = thread::spawn(move || {
                while !stop_clone.load(Ordering::SeqCst) {
                    {
                        let mut c = comp_clone.lock().expect("lock");
                        c.tick();
                    }
                    match receiver.recv_timeout(Duration::from_millis(5)) {
                        Ok(msg) => {
                            let mut c = comp_clone.lock().expect("lock");
                            apply_boundary_message(&mut c, DeviceState::DirectAll, msg);
                        }
                        Err(BoundaryRecvError::Timeout) | Err(BoundaryRecvError::Empty) => {}
                        Err(BoundaryRecvError::Disconnected) => break,
                    }
                }
            });

            let socket_server = SocketServer::bind(&socket_path).expect("bind socket");
            let server_handle = socket_server
                .spawn(sender, ServerConfig::default())
                .expect("spawn server");

            Self {
                _socket_dir: socket_dir,
                socket_path,
                server_handle: Some(server_handle),
                render_stop,
                render_join: Some(render_join),
            }
        }

        fn start() -> Self {
            let socket_dir = TestDir::new("client-test");
            let socket_path = socket_dir.path().join("gem80-test.sock");
            Self::start_with_path(socket_dir, socket_path)
        }

        fn stop(&mut self) {
            self.server_handle = None;
            self.render_stop.store(true, Ordering::SeqCst);
            if let Some(j) = self.render_join.take() {
                let _ = j.join();
            }
        }
    }

    impl Drop for TestServer {
        fn drop(&mut self) {
            self.stop();
        }
    }

    #[test]
    fn connect_when_no_daemon_fails_immediately() {
        let nonexistent = PathBuf::from("/tmp/does_not_exist_gem80_test.sock");
        let start = std::time::Instant::now();
        let result = Client::connect_to(&nonexistent);
        assert!(
            result.is_err(),
            "connecting to nonexistent socket must fail"
        );
        assert!(
            start.elapsed() < Duration::from_millis(500),
            "connection attempt without daemon must fail quickly without hanging"
        );
        match result.unwrap_err() {
            ClientError::Connect { path, source } => {
                assert_eq!(path, nonexistent);
                assert_eq!(source.kind(), std::io::ErrorKind::NotFound);
            }
            other => panic!("expected ClientError::Connect, got {other:?}"),
        }
    }

    #[test]
    fn register_layer_sparse_update_and_status() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        assert!(client.is_connected());
        assert_eq!(client.active_layer_count(), 0);

        let handle = client
            .register_layer("indicators", 50)
            .expect("register layer");

        assert_eq!(client.active_layer_count(), 1);
        assert_eq!(handle.name().unwrap(), "indicators");
        assert_eq!(handle.z_order().unwrap(), 50);

        // Sparse pixel update (R14)
        handle
            .set_pixel(5, Color::rgb(255, 0, 0))
            .expect("set pixel 5");
        handle
            .set_pixel(10, Color::rgb(0, 255, 0))
            .expect("set pixel 10");

        // Query status and verify active layer and composite pixels
        let status = client.status().expect("query status");
        assert_eq!(status.device_state, ClientDeviceState::DirectAll);
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].name, "indicators");
        assert_eq!(status.layers[0].pixel_count, 2);

        let frame = client.composite_frame().expect("composite frame");
        assert_eq!(frame[5], Color::rgb(255, 0, 0));
        assert_eq!(frame[10], Color::rgb(0, 255, 0));
        // Untouched LEDs show base color (10, 20, 30)
        assert_eq!(frame[0], Color::rgb(10, 20, 30));

        // Retract pixel 5 (R24): lower layer color shines through
        handle.retract_pixel(5).expect("retract pixel 5");
        let frame2 = client
            .composite_frame()
            .expect("composite frame after retract");
        assert_eq!(frame2[5], Color::rgb(10, 20, 30));
        assert_eq!(frame2[10], Color::rgb(0, 255, 0));
    }

    #[test]
    fn dropping_handle_sends_release_r15() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        {
            let handle = client
                .register_layer("transient", 100)
                .expect("register transient layer");
            handle
                .set_pixel(1, Color::rgb(111, 222, 111))
                .expect("set pixel");

            let frame = client.composite_frame().expect("frame with layer");
            assert_eq!(frame[1], Color::rgb(111, 222, 111));
            assert_eq!(client.active_layer_count(), 1);
            assert_eq!(client.layers().expect("layers").len(), 1);
            // handle is dropped here
        }

        assert_eq!(client.active_layer_count(), 0);

        // After drop, daemon received ReleaseLayerRequest and layer is unmounted
        let layers = client.layers().expect("layers after release");
        assert!(layers.is_empty(), "layer must be released on drop");

        let frame = client.composite_frame().expect("frame after release");
        assert_eq!(frame[1], Color::rgb(10, 20, 30), "reverts to base color");
    }

    #[test]
    fn multiple_layers_single_connection_r12() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        let handle1 = client.register_layer("bottom", 10).expect("layer 1");
        let handle2 = client.register_layer("top", 20).expect("layer 2");

        assert_eq!(client.active_layer_count(), 2);

        // Bottom layer paints LED 7 green
        handle1
            .set_pixel(7, Color::rgb(0, 255, 0))
            .expect("set bottom");
        // Top layer paints LED 7 red (overwrites bottom due to z=20 > z=10)
        handle2
            .set_pixel(7, Color::rgb(255, 0, 0))
            .expect("set top");

        let frame = client.composite_frame().expect("frame");
        assert_eq!(frame[7], Color::rgb(255, 0, 0));

        // Dropping top handle releases top layer only
        drop(handle2);

        assert_eq!(client.active_layer_count(), 1);
        let frame2 = client.composite_frame().expect("frame after top dropped");
        assert_eq!(
            frame2[7],
            Color::rgb(0, 255, 0),
            "bottom layer shows through after top dropped"
        );

        // Bottom handle remains fully functional
        handle1
            .set_pixel(8, Color::rgb(0, 0, 255))
            .expect("set bottom 8");
        let frame3 = client.composite_frame().expect("frame");
        assert_eq!(frame3[8], Color::rgb(0, 0, 255));
    }

    #[test]
    fn reconnect_reregisters_held_layers_r16() {
        let socket_dir = TestDir::new("reconnect-test");
        let socket_path = socket_dir.path().join("gem80-reconnect.sock");

        // 1. Start initial daemon instance
        let mut server = TestServer::start_with_path(socket_dir, socket_path.clone());
        let client = Client::connect_to(&socket_path).expect("connect client");

        let handle = client
            .register_layer("persistent", 30)
            .expect("register layer");
        handle
            .set_pixel(42, Color::rgb(123, 234, 45))
            .expect("set pixel 42");

        let frame1 = client.composite_frame().expect("frame 1");
        assert_eq!(frame1[42], Color::rgb(123, 234, 45));

        // 2. Stop the daemon (simulating crash or restart)
        server.stop();

        // 3. Start a new daemon instance on the exact same socket path
        let new_socket_dir = TestDir::new("reconnect-test-new");
        let _server2 = TestServer::start_with_path(new_socket_dir, socket_path.clone());

        // 4. Reconnect the client (R16): held layer is re-registered with its colors
        client.reconnect().expect("client reconnect");

        // Verify layer and pixels exist on the new daemon
        let status = client.status().expect("status on new daemon");
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].name, "persistent");
        assert_eq!(status.layers[0].z_order, 30);

        let frame2 = client.composite_frame().expect("frame on new daemon");
        assert_eq!(frame2[42], Color::rgb(123, 234, 45));

        // Handle continues to be fully functional on the new daemon
        handle
            .set_pixel(43, Color::rgb(200, 100, 50))
            .expect("update on new daemon");
        let frame3 = client.composite_frame().expect("frame 3");
        assert_eq!(frame3[43], Color::rgb(200, 100, 50));
    }

    #[test]
    fn transparent_auto_reconnect_on_update_when_daemon_restarted() {
        let socket_dir = TestDir::new("auto-reconnect-test");
        let socket_path = socket_dir.path().join("gem80-auto-reconnect.sock");

        let mut server = TestServer::start_with_path(socket_dir, socket_path.clone());
        let client = Client::connect_to(&socket_path).expect("connect client");

        let handle = client.register_layer("auto", 25).expect("register layer");
        handle
            .set_pixel(20, Color::rgb(11, 22, 33))
            .expect("set pixel");

        // Kill daemon
        server.stop();

        // Restart new daemon on same path
        let new_socket_dir = TestDir::new("auto-reconnect-test-2");
        let _server2 = TestServer::start_with_path(new_socket_dir, socket_path);

        // Calling set_pixel directly without explicit client.reconnect() must succeed!
        handle
            .set_pixel(21, Color::rgb(44, 55, 66))
            .expect("auto reconnect set pixel");

        let frame = client.composite_frame().expect("composite frame");
        assert_eq!(frame[20], Color::rgb(11, 22, 33), "previous pixel restored");
        assert_eq!(frame[21], Color::rgb(44, 55, 66), "new pixel applied");
    }

    #[test]
    fn invalid_led_index_rejected_clearly() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        let handle = client.register_layer("bounds", 10).expect("layer");

        // Index 101 is out of bounds for 101 LEDs (0..100)
        let err = handle.set_pixel(101, Color::rgb(255, 255, 255));
        assert!(err.is_err());
        match err.unwrap_err() {
            ClientError::InvalidLedIndex { index, max } => {
                assert_eq!(index, 101);
                assert_eq!(max, 100);
            }
            other => panic!("expected InvalidLedIndex, got {other:?}"),
        }

        // Connection remains alive and valid index works
        handle
            .set_pixel(0, Color::rgb(10, 10, 10))
            .expect("valid index 0");
        let frame = client.composite_frame().expect("frame");
        assert_eq!(frame[0], Color::rgb(10, 10, 10));
    }

    #[test]
    fn release_consumed_handle_prevents_subsequent_use() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        let handle = client.register_layer("explicit", 15).expect("layer");
        handle.release().expect("explicit release");

        assert_eq!(client.active_layer_count(), 0);
    }

    #[test]
    fn layer_with_lifetime_reported_and_retract_multiple() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        let handle = client
            .register_layer_with_lifetime("short_lived", 40, Some(Duration::from_millis(5000)))
            .expect("register with lifetime");

        handle
            .set_pixels([
                (30, Color::rgb(1, 1, 1)),
                (31, Color::rgb(2, 2, 2)),
                (32, Color::rgb(3, 3, 3)),
            ])
            .expect("set 3 pixels");

        let status = client.status().expect("status");
        assert_eq!(status.layers.len(), 1);
        assert!(status.layers[0].remaining_lifetime.is_some());

        // Retract multiple pixels: 30 and 32
        handle.retract_pixels([30, 32]).expect("retract multiple");

        let frame = client.composite_frame().expect("composite");
        assert_eq!(frame[30], Color::rgb(10, 20, 30), "30 retracted to base");
        assert_eq!(frame[31], Color::rgb(2, 2, 2), "31 still set");
        assert_eq!(frame[32], Color::rgb(10, 20, 30), "32 retracted to base");
    }

    /// Every LED the replay cache currently holds for a handle.
    fn cached_pixels(client: &Client, handle: &LayerHandle) -> HashMap<u32, Color> {
        client
            .inner
            .lock()
            .expect("client lock")
            .layers
            .get(&handle.handle_id)
            .expect("the handle's registration")
            .pixels
            .clone()
    }

    /// Test scenario: 데몬이 거절한 픽셀은 재생 캐시에 남지 않는다. 받아들여진 것만 남아
    /// 재연결 때 다시 적용된다 (E1, R16).
    #[test]
    fn rejected_update_does_not_enter_the_replay_cache_e1() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        // A layer the daemon expires on its own while the client keeps the handle.
        let handle = client
            .register_layer_with_lifetime("ephemeral", 10, Some(Duration::from_millis(50)))
            .expect("register with a short lifetime");
        handle
            .set_pixel(3, Color::rgb(1, 2, 3))
            .expect("the first write is accepted");
        assert_eq!(
            cached_pixels(&client, &handle).get(&3),
            Some(&Color::rgb(1, 2, 3)),
            "an accepted write belongs in the cache"
        );

        // Once the lifetime is up the daemon no longer has the layer, so the next
        // write comes back as a refusal.
        thread::sleep(Duration::from_millis(300));
        let err = handle.set_pixel(7, Color::rgb(9, 9, 9));
        match err {
            Err(ClientError::Rejected { reason, .. }) => {
                assert_eq!(reason, RejectionReason::LayerNotFound)
            }
            other => panic!("the write must be refused, got {other:?}"),
        }

        let cached = cached_pixels(&client, &handle);
        assert!(
            !cached.contains_key(&7),
            "a refused write must not sit in the cache waiting to be replayed, got {cached:?}"
        );
        assert_eq!(
            cached.get(&3),
            Some(&Color::rgb(1, 2, 3)),
            "the refusal must not disturb what was accepted"
        );
    }

    /// Test scenario: 받아들여진 픽셀만 재연결에서 재적용된다 (E1, R16).
    #[test]
    fn only_accepted_pixels_are_replayed_on_reconnect_e1() {
        let socket_dir = TestDir::new("e1-replay");
        let socket_path = socket_dir.path().join("gem80-e1-replay.sock");
        let mut server = TestServer::start_with_path(socket_dir, socket_path.clone());
        let client = Client::connect_to(&socket_path).expect("connect client");

        let handle = client.register_layer("cached", 10).expect("register layer");
        handle
            .set_pixel(3, Color::rgb(1, 2, 3))
            .expect("an accepted pixel");

        // A write the API refuses, for any reason, must leave no trace to replay.
        assert!(matches!(
            handle.set_pixel(GEM80_TOTAL_LEDS, Color::rgb(9, 9, 9)),
            Err(ClientError::InvalidLedIndex { .. })
        ));
        assert_eq!(cached_pixels(&client, &handle).len(), 1);

        server.stop();
        let new_dir = TestDir::new("e1-replay-2");
        let _server2 = TestServer::start_with_path(new_dir, socket_path);
        client.reconnect().expect("reconnect");

        let frame = client.composite_frame().expect("composite after reconnect");
        assert_eq!(
            frame[3],
            Color::rgb(1, 2, 3),
            "the accepted pixel is replayed"
        );
        assert_eq!(
            frame[GEM80_TOTAL_LEDS - 1],
            Color::rgb(10, 20, 30),
            "nothing the API refused reappears"
        );
    }

    /// Test scenario: 재연결은 남은 수명을 알리고, 이미 만료된 레이어는 되살리지 않는다 (E3).
    #[test]
    fn reconnect_reannounces_the_remaining_lifetime_e3() {
        let socket_dir = TestDir::new("e3-lifetime");
        let socket_path = socket_dir.path().join("gem80-e3.sock");
        let mut server = TestServer::start_with_path(socket_dir, socket_path.clone());
        let client = Client::connect_to(&socket_path).expect("connect client");

        let _long = client
            .register_layer_with_lifetime("long", 10, Some(Duration::from_millis(3000)))
            .expect("register the long-lived layer");
        let _short = client
            .register_layer_with_lifetime("short", 20, Some(Duration::from_millis(120)))
            .expect("register the short-lived layer");
        assert_eq!(client.active_layer_count(), 2);

        let before = client
            .status()
            .expect("status")
            .layers
            .iter()
            .find(|l| l.name == "long")
            .and_then(|l| l.remaining_lifetime)
            .expect("the long layer reports a lifetime");

        // Time passes with the daemon gone, and the short lease runs out.
        server.stop();
        thread::sleep(Duration::from_millis(400));
        let new_dir = TestDir::new("e3-lifetime-2");
        let _server2 = TestServer::start_with_path(new_dir, socket_path);
        client.reconnect().expect("reconnect");

        let layers = client.status().expect("status after reconnect").layers;
        assert_eq!(
            layers.len(),
            1,
            "a lease that expired while disconnected must not come back, got {layers:?}"
        );
        let after = layers[0]
            .remaining_lifetime
            .expect("the surviving layer keeps a lifetime");
        assert_eq!(layers[0].name, "long");
        assert!(
            after < before,
            "the reconnect must announce what is left ({after:?}), not the original lease ({before:?})"
        );
        assert_eq!(client.active_layer_count(), 1);
    }

    /// Test scenario: 밀리초로 표현할 수 없는 수명은 잘리지 않고 거절된다 (E4).
    #[test]
    fn lifetimes_outside_the_wire_range_are_refused_e4() {
        let server = TestServer::start();
        let client = Client::connect_to(&server.socket_path).expect("connect client");

        // Under a millisecond would round to zero, which the daemon reads as "no
        // lifetime": a layer asked to live 500 us would become permanent.
        let err = client.register_layer_with_lifetime(
            "sub-millisecond",
            1,
            Some(Duration::from_micros(500)),
        );
        assert!(
            matches!(err, Err(ClientError::LifetimeOutOfRange(_))),
            "a sub-millisecond lifetime must not silently become permanent, got {err:?}"
        );

        // Past u32::MAX milliseconds would wrap into a short lease or zero.
        let err = client.register_layer_with_lifetime(
            "too-long",
            1,
            Some(Duration::from_millis(u64::from(u32::MAX) + 1)),
        );
        assert!(
            matches!(err, Err(ClientError::LifetimeOutOfRange(_))),
            "an oversized lifetime must not wrap, got {err:?}"
        );

        assert_eq!(client.active_layer_count(), 0);
        // The boundaries themselves are accepted.
        client
            .register_layer_with_lifetime("exactly-one-ms", 1, Some(Duration::from_millis(1)))
            .expect("1 ms is representable");
        client
            .register_layer_with_lifetime(
                "largest",
                2,
                Some(Duration::from_millis(u64::from(u32::MAX))),
            )
            .expect("u32::MAX ms is representable");
    }

    /// Test scenario: 요청 ID가 어긋난 응답은 받아들이지 않고 스트림을 버린다 (E5).
    #[test]
    fn a_response_for_another_request_is_refused_e5() {
        use std::io::Write;

        let dir = TestDir::new("e5-mismatch");
        let socket_path = dir.path().join("gem80-e5.sock");
        let listener =
            std::os::unix::net::UnixListener::bind(&socket_path).expect("bind a stub daemon");

        // A stub daemon that answers every request with request_id 999.
        let stub = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let (_, _body) = crate::wire::read_frame(&mut stream).expect("read the request");
            let response = ServerMessage {
                request_id: 999,
                payload: Some(proto::server_message::Payload::GetStatus(
                    crate::wire::GetStatusResponse {
                        device_state: DeviceState::Absent as i32,
                        layers: Vec::new(),
                        composite_pixels: Vec::new(),
                    },
                )),
            };
            let body = prost::Message::encode_to_vec(&response);
            let frame = crate::wire::encode_frame(WireMessageDiscriminator::Control, &body)
                .expect("encode the response");
            stream.write_all(&frame).expect("write the response");
            // Hold the connection so the client's own read is what ends the
            // exchange, not an EOF.
            thread::sleep(Duration::from_millis(300));
        });

        let client = Client::connect_to(&socket_path).expect("connect client");
        let err = client.get_status(false, false);
        match err {
            Err(ClientError::ResponseMismatch { expected, actual }) => {
                assert_eq!(actual, 999);
                assert_ne!(expected, 999);
            }
            other => panic!("a mismatched response must be an error, got {other:?}"),
        }
        assert!(
            !client.is_connected(),
            "a stream one response out of step is unusable and must be dropped"
        );
        let _ = stub.join();
    }

    /// Test scenario: 연결 상한에 걸린 클라이언트는 왜 거절되었는지 그대로 받는다.
    ///
    /// The daemon writes that notice on its own initiative with request ID zero, so
    /// the strict matching of E5 must not turn it into a bare mismatch error.
    #[test]
    fn the_connection_limit_notice_reaches_the_client_as_a_rejection_e5() {
        let socket_dir = TestDir::new("e5-limit");
        let socket_path = socket_dir.path().join("gem80-e5-limit.sock");

        let (sender, receiver) = boundary_channel(16);
        let compositor = Arc::new(Mutex::new(Compositor::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_compositor = Arc::clone(&compositor);
        let thread_stop = Arc::clone(&stop);
        let render = thread::spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                match receiver.recv_timeout(Duration::from_millis(5)) {
                    Ok(msg) => {
                        let mut guard = thread_compositor.lock().expect("lock");
                        apply_boundary_message(&mut guard, DeviceState::Absent, msg);
                    }
                    Err(BoundaryRecvError::Timeout) | Err(BoundaryRecvError::Empty) => {}
                    Err(BoundaryRecvError::Disconnected) => break,
                }
            }
        });

        let server = SocketServer::bind(&socket_path).expect("bind");
        let handle = server
            .spawn(
                sender,
                ServerConfig {
                    max_connections: 1,
                    ..ServerConfig::default()
                },
            )
            .expect("spawn");

        let first = Client::connect_to(&socket_path).expect("the first client gets in");
        first
            .get_status(false, false)
            .expect("the first client works");

        // The second client is over the limit.
        let second = Client::connect_to(&socket_path).expect("connect is accepted, then refused");
        match second.get_status(false, false) {
            Err(ClientError::Rejected {
                reason, message, ..
            }) => {
                assert_eq!(reason, RejectionReason::Busy);
                assert!(
                    message.contains("connection limit"),
                    "the reason must survive, got {message:?}"
                );
            }
            other => panic!("the limit notice must arrive as a rejection, got {other:?}"),
        }

        drop(handle);
        stop.store(true, Ordering::SeqCst);
        let _ = render.join();
    }

    /// Test scenario: 레이어 해제가 전송 단계에서 실패하면 오류가 돌아오고 스트림이
    /// 무효화되어, 다음 호출이 재연결하면서 데몬이 그 레이어를 정리한다 (E2, R13, R16).
    #[test]
    fn a_failed_release_reports_and_invalidates_the_stream_e2() {
        let socket_dir = TestDir::new("e2-release");
        let socket_path = socket_dir.path().join("gem80-e2.sock");
        let mut server = TestServer::start_with_path(socket_dir, socket_path.clone());
        let client = Client::connect_to(&socket_path).expect("connect client");

        let handle = client
            .register_layer("released", 10)
            .expect("register layer");
        handle.set_pixel(2, Color::rgb(5, 5, 5)).expect("set pixel");
        assert!(client.is_connected());

        // The daemon goes away, so the release cannot get through.
        server.stop();

        let err = handle.release();
        assert!(
            matches!(err, Err(ClientError::Io(_)) | Err(ClientError::Framing(_))),
            "a release that did not reach the daemon must not be reported as success, got {err:?}"
        );
        assert!(
            !client.is_connected(),
            "the stream must be dropped so the next call reconnects"
        );
        assert_eq!(client.active_layer_count(), 0);

        // A replacement daemon takes over; the next call reconnects cleanly and the
        // released layer is not re-announced.
        let new_dir = TestDir::new("e2-release-2");
        let _server2 = TestServer::start_with_path(new_dir, socket_path);
        let layers = client.layers().expect("layers on the new daemon");
        assert!(
            layers.is_empty(),
            "the released layer must not come back, got {layers:?}"
        );
    }

    /// Test scenario: 합성 프레임 뒤에 붙은 잉여 바이트는 프로토콜 위반으로 거절된다 (E6).
    #[test]
    fn a_composite_frame_with_trailing_bytes_is_refused_e6() {
        use std::io::Write;

        let dir = TestDir::new("e6-trailing");
        let socket_path = dir.path().join("gem80-e6.sock");
        let listener =
            std::os::unix::net::UnixListener::bind(&socket_path).expect("bind a stub daemon");

        // 304 bytes: 101 whole pixels and one byte over. Discarding the remainder
        // would let this pass the pixel-count check.
        let stub = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let (_, body) = crate::wire::read_frame(&mut stream).expect("read the request");
            let request: ClientMessage =
                prost::Message::decode(body.as_slice()).expect("decode the request");
            let response = ServerMessage {
                request_id: request.request_id,
                payload: Some(proto::server_message::Payload::GetStatus(
                    crate::wire::GetStatusResponse {
                        device_state: DeviceState::DirectAll as i32,
                        layers: Vec::new(),
                        composite_pixels: vec![7u8; GEM80_TOTAL_LEDS * 3 + 1],
                    },
                )),
            };
            let body = prost::Message::encode_to_vec(&response);
            let frame = crate::wire::encode_frame(WireMessageDiscriminator::Control, &body)
                .expect("encode the response");
            stream.write_all(&frame).expect("write the response");
            thread::sleep(Duration::from_millis(300));
        });

        let client = Client::connect_to(&socket_path).expect("connect client");
        match client.get_status(false, true) {
            Err(ClientError::UnexpectedResponse(message)) => assert!(
                message.contains("304"),
                "the error must name the offending length, got {message:?}"
            ),
            other => panic!("trailing bytes must be refused, got {other:?}"),
        }
        let _ = stub.join();
    }
}
