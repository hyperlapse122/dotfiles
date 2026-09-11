//! AF_UNIX socket server, connection threads, and channel bridge.
//!
//! Thread-per-connection sockets meet the single render thread across one bounded
//! boundary channel (KTD7). Errors split into two layers (KTD8): framing and
//! deserialization failures close only the offending connection (R18), while
//! semantically wrong but well-formed requests get a structured rejection and keep
//! the connection alive (R17). Connection cleanup rides reserved capacity so a
//! saturated queue can never strand a dead client's layers (R13).

use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use prost::Message as _;

use crate::compositor::{Color, Compositor, CompositorError};
use crate::wire::{
    proto, ClientMessage, CompositeZIndex, ConnectionId, DeviceState, FixedPixelFrame,
    GetStatusResponse, LayerId, RejectionReason, RejectionResponse, ServerMessage,
    WireMessageDiscriminator, GEM80_TOTAL_LEDS,
};

/// Capacity of the ordinary-request side of the boundary channel (KTD7).
pub const BOUNDARY_CHANNEL_CAPACITY: usize = 256;

/// Upper bound on simultaneously served client connections (KTD7).
pub const DEFAULT_MAX_CONNECTIONS: usize = 64;

/// How long a connection thread waits for the render thread's reply before
/// answering with a structured rejection (KTD7, KTD8).
pub const DEFAULT_RESPONSE_TIMEOUT: Duration = Duration::from_millis(1500);

/// Interval the accept loop sleeps after a transient accept error.
const ACCEPT_ERROR_BACKOFF: Duration = Duration::from_millis(50);

/// Tunable limits for the socket server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ServerConfig {
    pub max_connections: usize,
    pub response_timeout: Duration,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            max_connections: DEFAULT_MAX_CONNECTIONS,
            response_timeout: DEFAULT_RESPONSE_TIMEOUT,
        }
    }
}

/// A semantically validated request on its way to the render thread.
#[derive(Debug, Clone, PartialEq)]
pub enum BoundaryRequest {
    RegisterLayer {
        name: String,
        z_order: CompositeZIndex,
        lifetime: Option<Duration>,
    },
    UpdateLayer {
        layer: LayerId,
        set_pixels: Vec<(usize, Color)>,
        retract_leds: Vec<usize>,
    },
    ReleaseLayer {
        layer: LayerId,
    },
    RetractPixels {
        layer: LayerId,
        led_indices: Vec<usize>,
    },
    GetStatus {
        include_layers: bool,
        include_composite_frame: bool,
    },
}

/// The render thread's answer to a single [`BoundaryRequest`].
#[derive(Debug, Clone, PartialEq)]
pub enum BoundaryResponse {
    LayerRegistered(LayerId),
    LayerUpdated(LayerId),
    LayerReleased(LayerId),
    PixelsRetracted(LayerId),
    Status(Box<GetStatusResponse>),
    Rejected(RejectionResponse),
}

/// A request paired with its one-shot reply channel.
#[derive(Debug)]
pub struct BoundaryCall {
    pub connection: ConnectionId,
    pub request: BoundaryRequest,
    pub reply: mpsc::Sender<BoundaryResponse>,
}

/// Everything the render thread receives over the boundary.
#[derive(Debug)]
pub enum BoundaryMessage {
    Call(BoundaryCall),
    /// Connection cleanup. Carried on reserved capacity: never dropped, never
    /// queued behind ordinary requests (R13, KTD7).
    ConnectionClosed(ConnectionId),
}

/// Why a call could not be queued.
#[derive(Debug)]
pub enum BoundarySendError {
    /// The bounded ordinary-request queue is full.
    Saturated(BoundaryCall),
    /// The render thread is gone.
    Disconnected(BoundaryCall),
}

/// Why a receive produced no message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoundaryRecvError {
    Empty,
    Timeout,
    Disconnected,
}

#[derive(Debug)]
struct BoundaryQueue {
    calls: VecDeque<BoundaryCall>,
    cleanups: VecDeque<ConnectionId>,
    senders: usize,
    receiver_alive: bool,
}

#[derive(Debug)]
struct BoundaryShared {
    capacity: usize,
    queue: Mutex<BoundaryQueue>,
    ready: Condvar,
}

/// Sending half of the boundary channel, held by connection threads.
#[derive(Debug)]
pub struct BoundarySender {
    shared: Arc<BoundaryShared>,
}

/// Receiving half of the boundary channel, held by the render thread (U7).
#[derive(Debug)]
pub struct BoundaryReceiver {
    shared: Arc<BoundaryShared>,
}

/// Creates a bounded boundary channel with reserved capacity for cleanup (KTD7).
pub fn boundary_channel(capacity: usize) -> (BoundarySender, BoundaryReceiver) {
    let shared = Arc::new(BoundaryShared {
        capacity: capacity.max(1),
        queue: Mutex::new(BoundaryQueue {
            calls: VecDeque::new(),
            cleanups: VecDeque::new(),
            senders: 1,
            receiver_alive: true,
        }),
        ready: Condvar::new(),
    });
    (
        BoundarySender {
            shared: Arc::clone(&shared),
        },
        BoundaryReceiver { shared },
    )
}

impl BoundarySender {
    /// Queues an ordinary request. Never blocks; rejects when the queue is full.
    pub fn try_send_call(&self, call: BoundaryCall) -> Result<(), BoundarySendError> {
        let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        if !queue.receiver_alive {
            return Err(BoundarySendError::Disconnected(call));
        }
        if queue.calls.len() >= self.shared.capacity {
            return Err(BoundarySendError::Saturated(call));
        }
        queue.calls.push_back(call);
        drop(queue);
        self.shared.ready.notify_one();
        Ok(())
    }

    /// Queues connection cleanup on reserved capacity. Always accepted (R13).
    pub fn send_connection_closed(&self, connection: ConnectionId) {
        let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        queue.cleanups.push_back(connection);
        drop(queue);
        self.shared.ready.notify_one();
    }

    /// Number of ordinary requests currently queued.
    pub fn pending_calls(&self) -> usize {
        let queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        queue.calls.len()
    }

    /// Whether the ordinary-request queue is at capacity.
    pub fn is_saturated(&self) -> bool {
        self.pending_calls() >= self.shared.capacity
    }
}

impl Clone for BoundarySender {
    fn clone(&self) -> Self {
        {
            let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
            queue.senders += 1;
        }
        Self {
            shared: Arc::clone(&self.shared),
        }
    }
}

impl Drop for BoundarySender {
    fn drop(&mut self) {
        {
            let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
            queue.senders = queue.senders.saturating_sub(1);
        }
        self.shared.ready.notify_all();
    }
}

impl BoundaryReceiver {
    /// Takes the next message, cleanup first, without blocking.
    pub fn try_recv(&self) -> Result<BoundaryMessage, BoundaryRecvError> {
        let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        match take_next(&mut queue) {
            Some(msg) => Ok(msg),
            None if queue.senders == 0 => Err(BoundaryRecvError::Disconnected),
            None => Err(BoundaryRecvError::Empty),
        }
    }

    /// Takes the next message, cleanup first, waiting up to `timeout`.
    pub fn recv_timeout(&self, timeout: Duration) -> Result<BoundaryMessage, BoundaryRecvError> {
        let deadline = Instant::now() + timeout;
        let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        loop {
            if let Some(msg) = take_next(&mut queue) {
                return Ok(msg);
            }
            if queue.senders == 0 {
                return Err(BoundaryRecvError::Disconnected);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(BoundaryRecvError::Timeout);
            }
            let (next, _) = self
                .shared
                .ready
                .wait_timeout(queue, deadline - now)
                .unwrap_or_else(|p| p.into_inner());
            queue = next;
        }
    }

    /// Drains everything currently queued, cleanup first.
    pub fn drain(&self) -> Vec<BoundaryMessage> {
        let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        let mut drained = Vec::with_capacity(queue.cleanups.len() + queue.calls.len());
        while let Some(msg) = take_next(&mut queue) {
            drained.push(msg);
        }
        drained
    }

    /// Number of ordinary requests currently queued.
    pub fn pending_calls(&self) -> usize {
        let queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        queue.calls.len()
    }

    /// Whether the ordinary-request queue is at capacity.
    pub fn is_saturated(&self) -> bool {
        self.pending_calls() >= self.shared.capacity
    }

    /// Whether a connection cleanup is waiting on reserved capacity.
    pub fn has_pending_cleanup(&self) -> bool {
        let queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        !queue.cleanups.is_empty()
    }
}

impl Drop for BoundaryReceiver {
    fn drop(&mut self) {
        let mut queue = self.shared.queue.lock().unwrap_or_else(|p| p.into_inner());
        queue.receiver_alive = false;
    }
}

fn take_next(queue: &mut BoundaryQueue) -> Option<BoundaryMessage> {
    if let Some(connection) = queue.cleanups.pop_front() {
        return Some(BoundaryMessage::ConnectionClosed(connection));
    }
    queue.calls.pop_front().map(BoundaryMessage::Call)
}

/// Applies one boundary message to the compositor and answers the caller.
///
/// The render thread (U7) owns the compositor and calls this for every drained
/// message. Semantic failures become structured rejections; nothing here closes a
/// connection (KTD8).
pub fn apply_boundary_message(
    compositor: &mut Compositor,
    device_state: DeviceState,
    message: BoundaryMessage,
) {
    let call = match message {
        BoundaryMessage::ConnectionClosed(connection) => {
            compositor.remove_connection_layers(connection);
            return;
        }
        BoundaryMessage::Call(call) => call,
    };

    let BoundaryCall {
        connection,
        request,
        reply,
    } = call;

    let response = match request {
        BoundaryRequest::RegisterLayer {
            name,
            z_order,
            lifetime,
        } => {
            let id = compositor.register_layer(Some(connection), name, z_order, lifetime);
            BoundaryResponse::LayerRegistered(id)
        }
        BoundaryRequest::UpdateLayer {
            layer,
            set_pixels,
            retract_leds,
        } => match owned_layer(compositor, connection, layer) {
            Err(rejection) => BoundaryResponse::Rejected(rejection),
            Ok(()) => match compositor.update_layer(layer, set_pixels, retract_leds) {
                Ok(()) => BoundaryResponse::LayerUpdated(layer),
                Err(e) => BoundaryResponse::Rejected(compositor_rejection(e, layer)),
            },
        },
        BoundaryRequest::ReleaseLayer { layer } => match owned_layer(compositor, connection, layer)
        {
            Err(rejection) => BoundaryResponse::Rejected(rejection),
            Ok(()) => match compositor.remove_layer(layer) {
                Ok(_) => BoundaryResponse::LayerReleased(layer),
                Err(e) => BoundaryResponse::Rejected(compositor_rejection(e, layer)),
            },
        },
        BoundaryRequest::RetractPixels { layer, led_indices } => {
            match owned_layer(compositor, connection, layer) {
                Err(rejection) => BoundaryResponse::Rejected(rejection),
                Ok(()) => match compositor.retract_pixels(layer, led_indices) {
                    Ok(()) => BoundaryResponse::PixelsRetracted(layer),
                    Err(e) => BoundaryResponse::Rejected(compositor_rejection(e, layer)),
                },
            }
        }
        BoundaryRequest::GetStatus {
            include_layers,
            include_composite_frame,
        } => BoundaryResponse::Status(Box::new(GetStatusResponse {
            device_state: device_state as i32,
            layers: if include_layers {
                compositor.layer_summaries()
            } else {
                Vec::new()
            },
            composite_pixels: if include_composite_frame {
                compositor.compose_bytes().to_vec()
            } else {
                Vec::new()
            },
        })),
    };

    // The caller may already have timed out; that is not an error here.
    let _ = reply.send(response);
}

/// Confirms the layer exists and belongs to this connection.
///
/// An update aimed at an expired layer lands here as a plain rejection: closing the
/// connection instead would take that client's other layers down with it (KTD8, AE11).
fn owned_layer(
    compositor: &Compositor,
    connection: ConnectionId,
    layer: LayerId,
) -> Result<(), RejectionResponse> {
    match compositor.get_layer(layer) {
        None => Err(reject(
            RejectionReason::LayerNotFound,
            format!("layer {} does not exist or has expired", layer.0),
            Some(layer),
        )),
        Some(existing) if existing.owner != Some(connection) => Err(reject(
            RejectionReason::PermissionDenied,
            format!("layer {} belongs to another connection", layer.0),
            Some(layer),
        )),
        Some(_) => Ok(()),
    }
}

fn compositor_rejection(error: CompositorError, layer: LayerId) -> RejectionResponse {
    match error {
        CompositorError::InvalidLedIndex(index) => reject(
            RejectionReason::LedIndexOutOfBounds,
            format!("LED index {index} is outside 0..{GEM80_TOTAL_LEDS}"),
            Some(layer),
        ),
        CompositorError::LayerNotFound(id) => reject(
            RejectionReason::LayerNotFound,
            format!("layer {} does not exist or has expired", id.0),
            Some(layer),
        ),
        CompositorError::BaseLayerImmutable => reject(
            RejectionReason::PermissionDenied,
            "the base layer is daemon-owned".to_string(),
            Some(layer),
        ),
        CompositorError::LayerAlreadyExists(id) => reject(
            RejectionReason::InvalidArgument,
            format!("layer {} already exists", id.0),
            Some(layer),
        ),
    }
}

fn reject(reason: RejectionReason, message: String, layer: Option<LayerId>) -> RejectionResponse {
    RejectionResponse {
        reason: reason as i32,
        message,
        layer_id: layer.map(|l| l.0),
    }
}

/// A bound AF_UNIX listener with `0o600` permissions, not yet serving.
#[derive(Debug)]
pub struct SocketServer {
    listener: UnixListener,
    path: PathBuf,
}

impl SocketServer {
    /// Binds the socket, replacing a stale node, and restricts it to the owner.
    ///
    /// Single-instance exclusion happens before this (U5, KTD4): by the time we get
    /// here, any socket still on disk is stale.
    pub fn bind(path: impl Into<PathBuf>) -> io::Result<Self> {
        let path = path.into();
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        Ok(Self { listener, path })
    }

    /// Binds the daemon's default runtime socket path.
    pub fn bind_default() -> io::Result<Self> {
        Self::bind(crate::paths::socket_path())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Starts the accept loop on its own thread.
    pub fn spawn(self, sender: BoundarySender, config: ServerConfig) -> io::Result<ServerHandle> {
        let SocketServer { listener, path } = self;
        let shutdown = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicUsize::new(0));
        let streams: SharedStreams = Arc::new(Mutex::new(HashMap::new()));

        let accept_shutdown = Arc::clone(&shutdown);
        let accept_active = Arc::clone(&active);
        let accept_streams = Arc::clone(&streams);
        let join = thread::Builder::new()
            .name("gem80-rgb-accept".to_string())
            .spawn(move || {
                accept_loop(
                    listener,
                    sender,
                    config,
                    accept_shutdown,
                    accept_active,
                    accept_streams,
                )
            })?;

        Ok(ServerHandle {
            path,
            shutdown,
            active,
            streams,
            join: Some(join),
        })
    }
}

type SharedStreams = Arc<Mutex<HashMap<ConnectionId, UnixStream>>>;

/// Owns the running server; dropping it stops the accept loop and unlinks the socket.
#[derive(Debug)]
pub struct ServerHandle {
    path: PathBuf,
    shutdown: Arc<AtomicBool>,
    active: Arc<AtomicUsize>,
    streams: SharedStreams,
    join: Option<thread::JoinHandle<()>>,
}

impl ServerHandle {
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Connections currently being served.
    pub fn active_connections(&self) -> usize {
        self.active.load(Ordering::SeqCst)
    }

    /// Stops the accept loop, drops live connections, and unlinks the socket.
    pub fn shutdown(&mut self) {
        if self.shutdown.swap(true, Ordering::SeqCst) {
            return;
        }
        // Wake the blocking accept() so the loop can observe the flag.
        let _ = UnixStream::connect(&self.path);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        {
            let mut streams = self.streams.lock().unwrap_or_else(|p| p.into_inner());
            for (_, stream) in streams.drain() {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

impl Drop for ServerHandle {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn accept_loop(
    listener: UnixListener,
    sender: BoundarySender,
    config: ServerConfig,
    shutdown: Arc<AtomicBool>,
    active: Arc<AtomicUsize>,
    streams: SharedStreams,
) {
    let next_connection = AtomicU64::new(1);

    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) => {
                if shutdown.load(Ordering::SeqCst) {
                    break;
                }
                log::warn!("gem80-rgb: accept failed ({e})");
                thread::sleep(ACCEPT_ERROR_BACKOFF);
                continue;
            }
        };
        if shutdown.load(Ordering::SeqCst) {
            break;
        }

        if active.load(Ordering::SeqCst) >= config.max_connections {
            let notice = ServerMessage {
                request_id: 0,
                payload: Some(proto::server_message::Payload::Rejection(reject(
                    RejectionReason::Busy,
                    format!(
                        "connection limit reached ({} concurrent connections)",
                        config.max_connections
                    ),
                    None,
                ))),
            };
            let _ = write_server_message(&stream, &notice);
            let _ = stream.shutdown(std::net::Shutdown::Both);
            continue;
        }

        let connection = ConnectionId(next_connection.fetch_add(1, Ordering::SeqCst));
        active.fetch_add(1, Ordering::SeqCst);
        if let Ok(clone) = stream.try_clone() {
            streams
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(connection, clone);
        }

        let connection_sender = sender.clone();
        let connection_active = Arc::clone(&active);
        let connection_streams = Arc::clone(&streams);
        let spawned = thread::Builder::new()
            .name(format!("gem80-rgb-conn-{}", connection.0))
            .spawn(move || {
                serve_connection(connection, &stream, &connection_sender, config);
                let _ = stream.shutdown(std::net::Shutdown::Both);
                // Cleanup rides reserved capacity: it reaches the render thread even
                // while ordinary requests are being rejected for saturation (R13).
                connection_sender.send_connection_closed(connection);
                connection_streams
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .remove(&connection);
                connection_active.fetch_sub(1, Ordering::SeqCst);
            });

        if let Err(e) = spawned {
            log::warn!("gem80-rgb: could not spawn connection thread ({e})");
            active.fetch_sub(1, Ordering::SeqCst);
            streams
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .remove(&connection);
            sender.send_connection_closed(connection);
        }
    }
}

/// Reads frames until the peer leaves or breaks framing (R18).
fn serve_connection(
    connection: ConnectionId,
    stream: &UnixStream,
    sender: &BoundarySender,
    config: ServerConfig,
) {
    let mut reader = stream;
    loop {
        let frame = match crate::wire::read_frame_optional(&mut reader) {
            Ok(Some(frame)) => frame,
            Ok(None) => return,
            Err(e) => {
                log::debug!("gem80-rgb: closing connection {} ({e})", connection.0);
                return;
            }
        };

        let response = match frame.0 {
            WireMessageDiscriminator::Control => match ClientMessage::decode(frame.1.as_slice()) {
                Ok(message) => handle_client_message(connection, message, sender, config),
                Err(e) => {
                    log::debug!(
                        "gem80-rgb: closing connection {} on decode error ({e})",
                        connection.0
                    );
                    return;
                }
            },
            WireMessageDiscriminator::PixelFrame => match FixedPixelFrame::decode_body(&frame.1) {
                // The push plane is wire-expressible but unimplemented in v1 (R17).
                Ok(pixel_frame) => ServerMessage {
                    request_id: 0,
                    payload: Some(proto::server_message::Payload::Rejection(reject(
                        RejectionReason::Unimplemented,
                        "push pixel frames are not implemented in v1".to_string(),
                        Some(pixel_frame.layer_id),
                    ))),
                },
                Err(e) => {
                    log::debug!(
                        "gem80-rgb: closing connection {} on pixel frame error ({e})",
                        connection.0
                    );
                    return;
                }
            },
        };

        if write_server_message(stream, &response).is_err() {
            return;
        }
    }
}

fn handle_client_message(
    connection: ConnectionId,
    message: ClientMessage,
    sender: &BoundarySender,
    config: ServerConfig,
) -> ServerMessage {
    let request_id = message.request_id;
    let request = match translate_payload(message.payload) {
        Ok(request) => request,
        Err(rejection) => return rejection_message(request_id, rejection),
    };

    let (reply_tx, reply_rx) = mpsc::channel();
    let call = BoundaryCall {
        connection,
        request,
        reply: reply_tx,
    };

    match sender.try_send_call(call) {
        Ok(()) => {}
        Err(BoundarySendError::Saturated(_)) => {
            return rejection_message(
                request_id,
                reject(
                    RejectionReason::Busy,
                    "daemon is saturated; retry shortly".to_string(),
                    None,
                ),
            );
        }
        Err(BoundarySendError::Disconnected(_)) => {
            return rejection_message(
                request_id,
                reject(
                    RejectionReason::Timeout,
                    "daemon render thread is unavailable".to_string(),
                    None,
                ),
            );
        }
    }

    // A silent render thread must not hang or close this connection (KTD7, KTD8).
    match reply_rx.recv_timeout(config.response_timeout) {
        Ok(response) => server_message(request_id, response),
        Err(_) => rejection_message(
            request_id,
            reject(
                RejectionReason::Timeout,
                format!(
                    "daemon did not answer within {} ms",
                    config.response_timeout.as_millis()
                ),
                None,
            ),
        ),
    }
}

/// Validates a client payload into a boundary request, or rejects it outright.
fn translate_payload(
    payload: Option<proto::client_message::Payload>,
) -> Result<BoundaryRequest, RejectionResponse> {
    let payload = payload.ok_or_else(|| {
        reject(
            RejectionReason::InvalidArgument,
            "control message carries no payload".to_string(),
            None,
        )
    })?;

    match payload {
        proto::client_message::Payload::RegisterLayer(req) => {
            if let Some(mode) = req.blend_mode {
                if mode != proto::BlendMode::Unspecified as i32
                    && mode != proto::BlendMode::Overwrite as i32
                {
                    return Err(reject(
                        RejectionReason::Unimplemented,
                        "v1 composites by overwrite only".to_string(),
                        None,
                    ));
                }
            }
            if let Some(opacity) = req.opacity {
                if (opacity - 1.0).abs() > f32::EPSILON {
                    return Err(reject(
                        RejectionReason::Unimplemented,
                        "layer opacity is not implemented in v1".to_string(),
                        None,
                    ));
                }
            }
            if req.push_fps.is_some_and(|fps| fps != 0) {
                return Err(reject(
                    RejectionReason::Unimplemented,
                    "push frames are not implemented in v1".to_string(),
                    None,
                ));
            }
            Ok(BoundaryRequest::RegisterLayer {
                name: req.name,
                z_order: CompositeZIndex(req.z_order),
                lifetime: req
                    .lifetime_ms
                    .filter(|ms| *ms > 0)
                    .map(|ms| Duration::from_millis(u64::from(ms))),
            })
        }
        proto::client_message::Payload::UpdateLayer(req) => {
            let layer = LayerId(req.layer_id);
            let mut set_pixels = Vec::with_capacity(req.set_pixels.len());
            for pixel in req.set_pixels {
                set_pixels.push(validate_pixel(pixel, layer)?);
            }
            let retract_leds = validate_led_indices(req.retract_leds, layer)?;
            Ok(BoundaryRequest::UpdateLayer {
                layer,
                set_pixels,
                retract_leds,
            })
        }
        proto::client_message::Payload::ReleaseLayer(req) => Ok(BoundaryRequest::ReleaseLayer {
            layer: LayerId(req.layer_id),
        }),
        proto::client_message::Payload::RetractPixels(req) => {
            let layer = LayerId(req.layer_id);
            Ok(BoundaryRequest::RetractPixels {
                layer,
                led_indices: validate_led_indices(req.led_indices, layer)?,
            })
        }
        proto::client_message::Payload::GetStatus(req) => Ok(BoundaryRequest::GetStatus {
            include_layers: req.include_layers,
            include_composite_frame: req.include_composite_frame,
        }),
    }
}

fn validate_pixel(
    pixel: crate::wire::LedColor,
    layer: LayerId,
) -> Result<(usize, Color), RejectionResponse> {
    let index = validate_led_index(pixel.led_index, layer)?;
    let channels = [pixel.red, pixel.green, pixel.blue];
    if channels.iter().any(|c| *c > u32::from(u8::MAX)) {
        return Err(reject(
            RejectionReason::InvalidArgument,
            format!(
                "LED {index} has a colour channel outside 0..=255: {:?}",
                channels
            ),
            Some(layer),
        ));
    }
    Ok((
        index,
        Color::rgb(pixel.red as u8, pixel.green as u8, pixel.blue as u8),
    ))
}

fn validate_led_indices(
    indices: Vec<u32>,
    layer: LayerId,
) -> Result<Vec<usize>, RejectionResponse> {
    indices
        .into_iter()
        .map(|index| validate_led_index(index, layer))
        .collect()
}

fn validate_led_index(index: u32, layer: LayerId) -> Result<usize, RejectionResponse> {
    let index = index as usize;
    if index >= GEM80_TOTAL_LEDS {
        return Err(reject(
            RejectionReason::LedIndexOutOfBounds,
            format!("LED index {index} is outside 0..{GEM80_TOTAL_LEDS}"),
            Some(layer),
        ));
    }
    Ok(index)
}

fn server_message(request_id: u64, response: BoundaryResponse) -> ServerMessage {
    let payload = match response {
        BoundaryResponse::LayerRegistered(layer) => {
            proto::server_message::Payload::RegisterLayer(crate::wire::RegisterLayerResponse {
                layer_id: layer.0,
            })
        }
        BoundaryResponse::LayerUpdated(layer) => {
            proto::server_message::Payload::UpdateLayer(crate::wire::UpdateLayerResponse {
                layer_id: layer.0,
            })
        }
        BoundaryResponse::LayerReleased(layer) => {
            proto::server_message::Payload::ReleaseLayer(crate::wire::ReleaseLayerResponse {
                layer_id: layer.0,
            })
        }
        BoundaryResponse::PixelsRetracted(layer) => {
            proto::server_message::Payload::RetractPixels(crate::wire::RetractPixelsResponse {
                layer_id: layer.0,
            })
        }
        BoundaryResponse::Status(status) => proto::server_message::Payload::GetStatus(*status),
        BoundaryResponse::Rejected(rejection) => {
            proto::server_message::Payload::Rejection(rejection)
        }
    };
    ServerMessage {
        request_id,
        payload: Some(payload),
    }
}

fn rejection_message(request_id: u64, rejection: RejectionResponse) -> ServerMessage {
    ServerMessage {
        request_id,
        payload: Some(proto::server_message::Payload::Rejection(rejection)),
    }
}

fn write_server_message(mut stream: &UnixStream, message: &ServerMessage) -> io::Result<()> {
    let body = message.encode_to_vec();
    crate::wire::write_frame(&mut stream, WireMessageDiscriminator::Control, &body)
        .map_err(|e| io::Error::other(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    use crate::compositor::{Color, Compositor};
    use crate::wire::{
        proto, ClientMessage, DeviceState, GetStatusRequest, LedColor, RegisterLayerRequest,
        RejectionReason, ReleaseLayerRequest, ServerMessage, UpdateLayerRequest,
    };

    /// Stand-in for the U7 render thread: owns a compositor and drains the boundary channel.
    struct FakeRender {
        compositor: Arc<Mutex<Compositor>>,
        stop: Arc<AtomicBool>,
        join: Option<thread::JoinHandle<()>>,
    }

    impl FakeRender {
        fn start(receiver: BoundaryReceiver) -> Self {
            let compositor = Arc::new(Mutex::new(Compositor::with_base_color(Color::rgb(1, 2, 3))));
            let stop = Arc::new(AtomicBool::new(false));
            let thread_compositor = Arc::clone(&compositor);
            let thread_stop = Arc::clone(&stop);
            let join = thread::spawn(move || {
                while !thread_stop.load(Ordering::SeqCst) {
                    {
                        let mut guard = thread_compositor.lock().expect("compositor lock");
                        guard.tick();
                    }
                    match receiver.recv_timeout(Duration::from_millis(5)) {
                        Ok(msg) => {
                            let mut guard = thread_compositor.lock().expect("compositor lock");
                            apply_boundary_message(&mut guard, DeviceState::Absent, msg);
                        }
                        Err(BoundaryRecvError::Timeout) | Err(BoundaryRecvError::Empty) => {}
                        Err(BoundaryRecvError::Disconnected) => break,
                    }
                }
            });
            Self {
                compositor,
                stop,
                join: Some(join),
            }
        }
    }

    impl Drop for FakeRender {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::SeqCst);
            if let Some(join) = self.join.take() {
                let _ = join.join();
            }
        }
    }

    struct TestClient {
        stream: UnixStream,
        next_request_id: u64,
    }

    impl TestClient {
        fn connect(path: &std::path::Path) -> Self {
            let stream = UnixStream::connect(path).expect("client connect");
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("read timeout");
            Self {
                stream,
                next_request_id: 1,
            }
        }

        fn send_payload(&mut self, payload: proto::client_message::Payload) -> u64 {
            let request_id = self.next_request_id;
            self.next_request_id += 1;
            let msg = ClientMessage {
                request_id,
                payload: Some(payload),
            };
            let frame = crate::wire::encode_client_frame(&msg).expect("encode client frame");
            self.stream.write_all(&frame).expect("write frame");
            request_id
        }

        fn read_response(&mut self) -> ServerMessage {
            let (discriminator, body) =
                crate::wire::read_frame(&mut self.stream).expect("read server frame");
            assert_eq!(
                discriminator,
                crate::wire::WireMessageDiscriminator::Control
            );
            <ServerMessage as prost::Message>::decode(body.as_slice()).expect("decode response")
        }

        fn call(&mut self, payload: proto::client_message::Payload) -> ServerMessage {
            let request_id = self.send_payload(payload);
            let response = self.read_response();
            assert_eq!(response.request_id, request_id);
            response
        }

        fn register(&mut self, name: &str, z_order: i32) -> u32 {
            let response = self.call(proto::client_message::Payload::RegisterLayer(
                RegisterLayerRequest {
                    name: name.to_string(),
                    z_order,
                    ..Default::default()
                },
            ));
            match response.payload {
                Some(proto::server_message::Payload::RegisterLayer(r)) => r.layer_id,
                other => panic!("expected RegisterLayer response, got {other:?}"),
            }
        }

        fn status(&mut self) -> crate::wire::GetStatusResponse {
            let response = self.call(proto::client_message::Payload::GetStatus(
                GetStatusRequest {
                    include_layers: true,
                    include_composite_frame: true,
                },
            ));
            match response.payload {
                Some(proto::server_message::Payload::GetStatus(r)) => r,
                other => panic!("expected GetStatus response, got {other:?}"),
            }
        }
    }

    fn rejection(response: &ServerMessage) -> &crate::wire::RejectionResponse {
        match &response.payload {
            Some(proto::server_message::Payload::Rejection(r)) => r,
            other => panic!("expected rejection, got {other:?}"),
        }
    }

    fn socket_path_in(dir: &std::path::Path) -> std::path::PathBuf {
        dir.join("gem80-rgb-test.sock")
    }

    struct TempDir(std::path::PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let base = std::env::temp_dir().join(format!(
                "gem80-rgb-server-{tag}-{}-{:?}",
                std::process::id(),
                thread::current().id()
            ));
            std::fs::create_dir_all(&base).expect("create temp dir");
            Self(base)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Starts a server backed by a fake render thread.
    fn start_server(dir: &TempDir, config: ServerConfig) -> (ServerHandle, FakeRender) {
        let (sender, receiver) = boundary_channel(BOUNDARY_CHANNEL_CAPACITY);
        let render = FakeRender::start(receiver);
        let server = SocketServer::bind(socket_path_in(dir.path())).expect("bind socket");
        let handle = server.spawn(sender, config).expect("spawn server");
        (handle, render)
    }

    fn wait_until(mut predicate: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if predicate() {
                return true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        false
    }

    /// Test scenario: 연결해서 레이어를 등록하면 합성 결과에 그 픽셀이 나타난다.
    #[test]
    fn test_registered_layer_pixels_appear_in_composite() {
        let dir = TempDir::new("composite");
        let (handle, _render) = start_server(&dir, ServerConfig::default());
        let mut client = TestClient::connect(handle.path());

        let layer_id = client.register("indicator", 10);
        let response = client.call(proto::client_message::Payload::UpdateLayer(
            UpdateLayerRequest {
                layer_id,
                set_pixels: vec![LedColor {
                    led_index: 7,
                    red: 200,
                    green: 100,
                    blue: 50,
                }],
                retract_leds: vec![],
            },
        ));
        assert!(matches!(
            response.payload,
            Some(proto::server_message::Payload::UpdateLayer(_))
        ));

        let status = client.status();
        assert_eq!(status.layers.len(), 1);
        assert_eq!(&status.composite_pixels[21..24], &[200, 100, 50]);
    }

    /// Test scenario: 연결을 끊으면 그 연결의 레이어가 전부 사라진다. Covers AE2.
    #[test]
    fn test_disconnect_removes_all_layers_ae2() {
        let dir = TempDir::new("disconnect");
        let (handle, render) = start_server(&dir, ServerConfig::default());

        let mut dying = TestClient::connect(handle.path());
        let dying_layer = dying.register("dying", 5);
        dying.call(proto::client_message::Payload::UpdateLayer(
            UpdateLayerRequest {
                layer_id: dying_layer,
                set_pixels: vec![LedColor {
                    led_index: 0,
                    red: 255,
                    green: 0,
                    blue: 0,
                }],
                retract_leds: vec![],
            },
        ));

        let mut survivor = TestClient::connect(handle.path());
        survivor.register("survivor", 1);

        drop(dying);

        assert!(
            wait_until(|| {
                let guard = render.compositor.lock().expect("compositor lock");
                guard.layer_count() == 1
            }),
            "dying connection's layer must be removed"
        );

        let guard = render.compositor.lock().expect("compositor lock");
        let frame = guard.compose();
        assert_eq!(
            frame[0],
            Color::rgb(1, 2, 3),
            "LED must fall back to the base layer color"
        );
    }

    /// Test scenario: 한 연결이 여러 레이어를 가질 수 있고, 하나를 해제해도 나머지는 남는다.
    #[test]
    fn test_one_connection_many_layers_release_keeps_others() {
        let dir = TempDir::new("multilayer");
        let (handle, _render) = start_server(&dir, ServerConfig::default());
        let mut client = TestClient::connect(handle.path());

        let first = client.register("first", 1);
        let second = client.register("second", 2);
        assert_ne!(first, second);
        assert_eq!(client.status().layers.len(), 2);

        let response = client.call(proto::client_message::Payload::ReleaseLayer(
            ReleaseLayerRequest { layer_id: first },
        ));
        assert!(matches!(
            response.payload,
            Some(proto::server_message::Payload::ReleaseLayer(_))
        ));

        let status = client.status();
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].layer_id, second);
    }

    /// Test scenario: 프레이밍이 깨진 메시지를 보낸 연결만 닫히고 다른 연결의 레이어는 남는다. Covers AE7.
    #[test]
    fn test_framing_error_closes_only_its_own_connection_ae7() {
        let dir = TempDir::new("framing");
        let (handle, render) = start_server(&dir, ServerConfig::default());

        let mut good = TestClient::connect(handle.path());
        let good_layer = good.register("good", 3);
        good.call(proto::client_message::Payload::UpdateLayer(
            UpdateLayerRequest {
                layer_id: good_layer,
                set_pixels: vec![LedColor {
                    led_index: 4,
                    red: 9,
                    green: 9,
                    blue: 9,
                }],
                retract_leds: vec![],
            },
        ));

        let mut bad = UnixStream::connect(handle.path()).expect("bad client connect");
        bad.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        // Declared payload length far beyond MAX_FRAME_PAYLOAD_BYTES.
        bad.write_all(&(crate::wire::MAX_FRAME_PAYLOAD_BYTES as u32 + 1).to_be_bytes())
            .expect("write bad prefix");
        bad.write_all(&[crate::wire::CONTROL_MESSAGE_MARKER, 0, 0])
            .expect("write bad body");

        let mut sink = [0u8; 64];
        let read = std::io::Read::read(&mut bad, &mut sink).expect("read from closed connection");
        assert_eq!(read, 0, "the offending connection must be closed");

        // The healthy connection still answers and still owns its layer.
        let status = good.status();
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].layer_id, good_layer);
        let guard = render.compositor.lock().expect("compositor lock");
        assert_eq!(guard.compose()[4], Color::rgb(9, 9, 9));
    }

    /// Test scenario: v1이 구현하지 않는 기능을 요청하면 거절이 돌아오고 연결은 열려 있다. Covers AE6.
    #[test]
    fn test_unimplemented_feature_rejected_connection_survives_ae6() {
        let dir = TempDir::new("unimplemented");
        let (handle, _render) = start_server(&dir, ServerConfig::default());
        let mut client = TestClient::connect(handle.path());

        let response = client.call(proto::client_message::Payload::RegisterLayer(
            RegisterLayerRequest {
                name: "pushy".to_string(),
                z_order: 1,
                push_fps: Some(60),
                ..Default::default()
            },
        ));
        assert_eq!(
            rejection(&response).reason,
            RejectionReason::Unimplemented as i32
        );

        let response = client.call(proto::client_message::Payload::RegisterLayer(
            RegisterLayerRequest {
                name: "blended".to_string(),
                z_order: 1,
                blend_mode: Some(crate::wire::BlendMode::Alpha as i32),
                ..Default::default()
            },
        ));
        assert_eq!(
            rejection(&response).reason,
            RejectionReason::Unimplemented as i32
        );

        // The connection is still usable afterwards.
        let layer_id = client.register("plain", 1);
        assert!(layer_id > 0);
    }

    /// Test scenario: 만료된 레이어 ID에 갱신을 보내면 거절이 돌아오고, 연결도 같은 클라이언트의
    /// 다른 레이어도 살아남는다. Covers AE11.
    #[test]
    fn test_update_to_expired_layer_rejected_without_closing_ae11() {
        let dir = TempDir::new("expired");
        let (handle, _render) = start_server(&dir, ServerConfig::default());
        let mut client = TestClient::connect(handle.path());

        let persistent = client.register("persistent", 1);
        let ephemeral = match client
            .call(proto::client_message::Payload::RegisterLayer(
                RegisterLayerRequest {
                    name: "ephemeral".to_string(),
                    z_order: 2,
                    lifetime_ms: Some(1),
                    ..Default::default()
                },
            ))
            .payload
        {
            Some(proto::server_message::Payload::RegisterLayer(r)) => r.layer_id,
            other => panic!("expected RegisterLayer response, got {other:?}"),
        };

        thread::sleep(Duration::from_millis(60));

        let response = client.call(proto::client_message::Payload::UpdateLayer(
            UpdateLayerRequest {
                layer_id: ephemeral,
                set_pixels: vec![LedColor {
                    led_index: 1,
                    red: 1,
                    green: 1,
                    blue: 1,
                }],
                retract_leds: vec![],
            },
        ));
        let reject = rejection(&response);
        assert_eq!(reject.reason, RejectionReason::LayerNotFound as i32);
        assert_eq!(reject.layer_id, Some(ephemeral));

        // Connection alive, sibling layer untouched.
        let status = client.status();
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].layer_id, persistent);
    }

    /// Test scenario: 범위 밖 LED 인덱스는 거절이지 연결 종료가 아니다.
    #[test]
    fn test_led_index_out_of_bounds_is_a_rejection() {
        let dir = TempDir::new("ledbounds");
        let (handle, _render) = start_server(&dir, ServerConfig::default());
        let mut client = TestClient::connect(handle.path());

        let layer_id = client.register("bounds", 1);
        let response = client.call(proto::client_message::Payload::UpdateLayer(
            UpdateLayerRequest {
                layer_id,
                set_pixels: vec![LedColor {
                    led_index: crate::wire::GEM80_TOTAL_LEDS as u32,
                    red: 1,
                    green: 2,
                    blue: 3,
                }],
                retract_leds: vec![],
            },
        ));
        assert_eq!(
            rejection(&response).reason,
            RejectionReason::LedIndexOutOfBounds as i32
        );

        // Connection survives and the layer is untouched.
        let status = client.status();
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].pixel_count, 0);
    }

    /// Test scenario: 소켓 파일 권한이 `0o600`이고 서버가 사라지면 언링크된다.
    #[test]
    fn test_socket_permissions_and_unlink_on_drop() {
        let dir = TempDir::new("perms");
        let (handle, render) = start_server(&dir, ServerConfig::default());
        let path = handle.path().to_path_buf();

        let mode = std::fs::metadata(&path)
            .expect("socket metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);

        drop(handle);
        drop(render);
        assert!(!path.exists(), "socket file must be unlinked");
    }

    /// Test scenario: 연결 상한에 도달하면 새 연결이 거절되고 기존 연결은 영향받지 않는다.
    #[test]
    fn test_connection_limit_rejects_new_connections() {
        let dir = TempDir::new("connlimit");
        let config = ServerConfig {
            max_connections: 1,
            ..ServerConfig::default()
        };
        let (handle, _render) = start_server(&dir, config);

        let mut first = TestClient::connect(handle.path());
        let layer_id = first.register("first", 1);
        assert!(wait_until(|| handle.active_connections() == 1));

        let mut second = UnixStream::connect(handle.path()).expect("second connect");
        second
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let (_, body) = crate::wire::read_frame(&mut second).expect("limit rejection frame");
        let msg =
            <ServerMessage as prost::Message>::decode(body.as_slice()).expect("decode rejection");
        assert!(matches!(
            msg.payload,
            Some(proto::server_message::Payload::Rejection(_))
        ));
        let mut sink = [0u8; 8];
        assert_eq!(
            std::io::Read::read(&mut second, &mut sink).expect("read after rejection"),
            0,
            "rejected connection must be closed"
        );

        // The existing connection keeps working.
        let status = first.status();
        assert_eq!(status.layers.len(), 1);
        assert_eq!(status.layers[0].layer_id, layer_id);
    }

    /// Test scenario: 경계 채널이 가득 차면 요청이 구조화된 오류로 거절되고 연결은 유지된다.
    #[test]
    fn test_saturated_boundary_channel_rejects_without_closing() {
        let dir = TempDir::new("saturated");
        // No render thread: nothing drains the channel.
        let (sender, receiver) = boundary_channel(1);
        let server = SocketServer::bind(socket_path_in(dir.path())).expect("bind");
        let handle = server
            .spawn(
                sender,
                ServerConfig {
                    response_timeout: Duration::from_millis(50),
                    ..ServerConfig::default()
                },
            )
            .expect("spawn");

        let mut client = TestClient::connect(handle.path());

        // First request occupies the single slot and times out waiting for a reply.
        let first = client.call(proto::client_message::Payload::GetStatus(
            GetStatusRequest {
                include_layers: false,
                include_composite_frame: false,
            },
        ));
        assert_eq!(
            rejection(&first).reason,
            RejectionReason::Timeout as i32,
            "unanswered request must time out into a structured rejection"
        );

        // Second request finds the channel saturated.
        let second = client.call(proto::client_message::Payload::GetStatus(
            GetStatusRequest {
                include_layers: false,
                include_composite_frame: false,
            },
        ));
        let reject = rejection(&second);
        assert_eq!(reject.reason, RejectionReason::Busy as i32);
        assert!(
            reject.message.contains("saturat"),
            "saturation rejection must say so, got {:?}",
            reject.message
        );

        // Connection still alive.
        let third = client.call(proto::client_message::Payload::GetStatus(
            GetStatusRequest {
                include_layers: false,
                include_composite_frame: false,
            },
        ));
        assert!(matches!(
            third.payload,
            Some(proto::server_message::Payload::Rejection(_))
        ));
        drop(receiver);
    }

    /// Test scenario: 렌더 스레드가 답하지 않으면 연결 스레드의 응답 대기가 타임아웃으로 끝난다.
    #[test]
    fn test_silent_render_thread_times_out_without_closing() {
        let dir = TempDir::new("timeout");
        let (sender, receiver) = boundary_channel(BOUNDARY_CHANNEL_CAPACITY);
        let server = SocketServer::bind(socket_path_in(dir.path())).expect("bind");
        let handle = server
            .spawn(
                sender,
                ServerConfig {
                    response_timeout: Duration::from_millis(50),
                    ..ServerConfig::default()
                },
            )
            .expect("spawn");

        let mut client = TestClient::connect(handle.path());
        let started = Instant::now();
        let response = client.call(proto::client_message::Payload::RegisterLayer(
            RegisterLayerRequest {
                name: "orphan".to_string(),
                z_order: 1,
                ..Default::default()
            },
        ));
        assert!(started.elapsed() < Duration::from_secs(2), "must not hang");
        assert_eq!(rejection(&response).reason, RejectionReason::Timeout as i32);

        // Still open for business.
        let again = client.call(proto::client_message::Payload::GetStatus(
            GetStatusRequest {
                include_layers: false,
                include_composite_frame: false,
            },
        ));
        assert!(matches!(
            again.payload,
            Some(proto::server_message::Payload::Rejection(_))
        ));
        drop(receiver);
    }

    /// Test scenario: 경계 채널을 일반 요청으로 가득 채운 상태에서 연결을 끊으면 그 레이어가
    /// 사라진다. 정리가 포화에 밀려 유실되지 않는다. Covers AE16.
    #[test]
    fn test_cleanup_survives_saturated_channel_ae16() {
        let dir = TempDir::new("ae16");
        let (sender, receiver) = boundary_channel(2);
        let server = SocketServer::bind(socket_path_in(dir.path())).expect("bind");
        let handle = server
            .spawn(
                sender,
                ServerConfig {
                    response_timeout: Duration::from_millis(30),
                    ..ServerConfig::default()
                },
            )
            .expect("spawn");

        let mut client = TestClient::connect(handle.path());
        for _ in 0..4 {
            let _ = client.call(proto::client_message::Payload::GetStatus(
                GetStatusRequest {
                    include_layers: false,
                    include_composite_frame: false,
                },
            ));
        }
        assert!(receiver.is_saturated(), "ordinary queue must be full");

        drop(client);

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut saw_cleanup = false;
        while Instant::now() < deadline && !saw_cleanup {
            if receiver.has_pending_cleanup() {
                saw_cleanup = true;
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(
            saw_cleanup,
            "connection cleanup must reach the render thread even while the queue is full"
        );

        // The cleanup is delivered ahead of the backlog it could not queue behind.
        match receiver.recv_timeout(Duration::from_millis(100)) {
            Ok(BoundaryMessage::ConnectionClosed(_)) => {}
            other => panic!("cleanup must be delivered first, got {other:?}"),
        }
    }

    /// Test scenario: 정리 메시지는 합성기에서 그 연결의 레이어를 전부 지운다 (R13).
    #[test]
    fn test_apply_connection_closed_removes_layers() {
        let mut compositor = Compositor::new();
        let connection = crate::wire::ConnectionId(9);
        let layer =
            compositor.register_layer(Some(connection), "x", crate::wire::CompositeZIndex(1), None);
        assert!(compositor.has_layer(layer));

        apply_boundary_message(
            &mut compositor,
            DeviceState::Absent,
            BoundaryMessage::ConnectionClosed(connection),
        );
        assert!(!compositor.has_layer(layer));
    }
}
