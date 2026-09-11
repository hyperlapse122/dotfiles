//! Wire protocol framing, protobuf message definitions, and fixed pixel frames.

use prost::Message;
use std::io::{Read, Write};

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/gem80rgb.rs"));
}

pub use proto::{
    BlendMode, ClientMessage, DeviceState, GetStatusRequest, GetStatusResponse, LayerSummary,
    LedColor, RegisterLayerRequest, RegisterLayerResponse, RejectionReason, RejectionResponse,
    ReleaseLayerRequest, ReleaseLayerResponse, RetractPixelsRequest, RetractPixelsResponse,
    ServerMessage, UpdateLayerRequest, UpdateLayerResponse,
};

/// Big-endian 4-byte length prefix configuration (Approach 1b).
pub const LENGTH_PREFIX_WIDTH_BYTES: usize = 4;

/// Upper limit for framed message payloads (64 KiB) to prevent memory allocation attacks (R18, KTD8).
pub const MAX_FRAME_PAYLOAD_BYTES: usize = 64 * 1024;

/// Discriminator marker identifying a Protobuf control message frame (Approach 1b).
pub const CONTROL_MESSAGE_MARKER: u8 = 0x01;

/// Discriminator marker identifying a raw fixed pixel frame (Approach 1b, KTD5).
pub const PIXEL_FRAME_MARKER: u8 = 0x02;

/// Total number of addressable LEDs on the NuPhy Gem80 (89 keys + 12 side).
pub const GEM80_TOTAL_LEDS: usize = 101;

/// Bytes per RGB LED (Red, Green, Blue).
pub const BYTES_PER_LED: usize = 3;

/// Total size in bytes for a full 101-LED RGB buffer (303 bytes).
pub const GEM80_PIXEL_BUFFER_BYTES: usize = GEM80_TOTAL_LEDS * BYTES_PER_LED;

/// Size of the pixel frame body excluding the 1-byte discriminator marker:
/// 4 bytes layer_id (BE) + 2 bytes pixel_count (BE) + 1 byte flags + 303 bytes pixels = 310 bytes.
pub const FIXED_PIXEL_FRAME_BODY_BYTES: usize = 4 + 2 + 1 + GEM80_PIXEL_BUFFER_BYTES;

/// Total byte length of the pixel frame payload (marker + body) on the wire:
/// 1 byte marker + 310 bytes body = 311 bytes.
pub const FIXED_PIXEL_FRAME_PAYLOAD_BYTES: usize = 1 + FIXED_PIXEL_FRAME_BODY_BYTES;

/// Total wire frame size for a fixed pixel frame including the 4-byte length prefix: 315 bytes.
pub const FIXED_PIXEL_FRAME_TOTAL_BYTES: usize =
    LENGTH_PREFIX_WIDTH_BYTES + FIXED_PIXEL_FRAME_PAYLOAD_BYTES;

/// Framing marker distinguishing control plane messages from high-throughput pixel frames (Approach 1b).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WireMessageDiscriminator {
    Control = CONTROL_MESSAGE_MARKER,
    PixelFrame = PIXEL_FRAME_MARKER,
}

impl TryFrom<u8> for WireMessageDiscriminator {
    type Error = u8;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            CONTROL_MESSAGE_MARKER => Ok(Self::Control),
            PIXEL_FRAME_MARKER => Ok(Self::PixelFrame),
            other => Err(other),
        }
    }
}

/// Zero-sized type encoding the length prefix format choice (4-byte big-endian unsigned integer).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BigEndianU32LengthPrefix;

/// Layer identifier issued by the daemon to a specific client connection (Approach 1b).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LayerId(pub u32);

/// Client connection identifier within the daemon process (Approach 1b).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ConnectionId(pub u64);

/// Z-order index for compositing: higher values sit on top of lower values (R7).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CompositeZIndex(pub i32);

/// Explicit millisecond duration type for layer lifetimes (Approach 1b, R10).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MillisecondLifetime(pub u32);

/// Errors encountered at the wire framing layer (R18, KTD8).
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FramingError {
    #[error("Frame length {size} exceeds maximum allowable size {max}")]
    OversizedFrame { size: usize, max: usize },
    #[error("Stream truncated: expected {expected} bytes, received {actual}")]
    Truncated { expected: usize, actual: usize },
    #[error("Encountered empty zero-length frame")]
    EmptyFrame,
    #[error("Unknown message discriminator: {0:#04x}")]
    InvalidDiscriminator(u8),
    /// The read timeout expired with no frame started.
    ///
    /// Distinct from [`FramingError::Io`], which covers a timeout that landed
    /// mid-frame: there the stream position is lost and the connection has to go,
    /// while here nothing was in flight and the caller may decide to keep waiting.
    #[error("Read timed out with no frame in progress")]
    IdleTimeout,
    #[error("I/O error: {0}")]
    Io(String),
}

/// Errors specific to fixed pixel frame decoding.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PixelFrameError {
    #[error("Discriminator mismatch: expected {expected:#04x}, got {actual:#04x}")]
    DiscriminatorMismatch { expected: u8, actual: u8 },
    #[error("Invalid pixel frame payload length: expected {expected}, got {actual}")]
    InvalidPayloadLength { expected: usize, actual: usize },
    #[error("Invalid pixel count: expected {expected}, got {actual}")]
    InvalidPixelCount { expected: u16, actual: u16 },
}

/// High-level errors across the wire module.
#[derive(Debug, thiserror::Error)]
pub enum WireError {
    #[error(transparent)]
    Framing(#[from] FramingError),
    #[error("Protobuf decode error: {0}")]
    ProtobufDecode(#[from] prost::DecodeError),
    #[error("Protobuf encode error: {0}")]
    ProtobufEncode(#[from] prost::EncodeError),
    #[error(transparent)]
    PixelFrame(#[from] PixelFrameError),
    #[error("Message discriminator mismatch: expected {expected:?}, got {actual:?}")]
    DiscriminatorMismatch {
        expected: WireMessageDiscriminator,
        actual: WireMessageDiscriminator,
    },
}

/// Fixed pixel frame bypassing Protobuf serialization (Approach 1b, KTD5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixedPixelFrame {
    pub layer_id: LayerId,
    pub flags: u8,
    pub pixels: [u8; GEM80_PIXEL_BUFFER_BYTES],
}

impl FixedPixelFrame {
    pub fn new(layer_id: LayerId, pixels: [u8; GEM80_PIXEL_BUFFER_BYTES]) -> Self {
        Self {
            layer_id,
            flags: 0,
            pixels,
        }
    }

    /// Encodes this pixel frame into its wire payload representation (including 1-byte marker).
    pub fn encode(&self) -> [u8; FIXED_PIXEL_FRAME_PAYLOAD_BYTES] {
        let mut buf = [0u8; FIXED_PIXEL_FRAME_PAYLOAD_BYTES];
        buf[0] = PIXEL_FRAME_MARKER;
        buf[1..5].copy_from_slice(&self.layer_id.0.to_be_bytes());
        buf[5..7].copy_from_slice(&(GEM80_TOTAL_LEDS as u16).to_be_bytes());
        buf[7] = self.flags;
        buf[8..8 + GEM80_PIXEL_BUFFER_BYTES].copy_from_slice(&self.pixels);
        buf
    }

    /// Encodes only the body (excluding the 1-byte marker).
    pub fn encode_body(&self) -> [u8; FIXED_PIXEL_FRAME_BODY_BYTES] {
        let mut buf = [0u8; FIXED_PIXEL_FRAME_BODY_BYTES];
        buf[0..4].copy_from_slice(&self.layer_id.0.to_be_bytes());
        buf[4..6].copy_from_slice(&(GEM80_TOTAL_LEDS as u16).to_be_bytes());
        buf[6] = self.flags;
        buf[7..7 + GEM80_PIXEL_BUFFER_BYTES].copy_from_slice(&self.pixels);
        buf
    }

    /// Decodes a pixel frame from a payload slice that includes the leading marker.
    pub fn decode(payload: &[u8]) -> Result<Self, PixelFrameError> {
        if payload.is_empty() {
            return Err(PixelFrameError::InvalidPayloadLength {
                expected: FIXED_PIXEL_FRAME_PAYLOAD_BYTES,
                actual: 0,
            });
        }
        if payload[0] != PIXEL_FRAME_MARKER {
            return Err(PixelFrameError::DiscriminatorMismatch {
                expected: PIXEL_FRAME_MARKER,
                actual: payload[0],
            });
        }
        if payload.len() != FIXED_PIXEL_FRAME_PAYLOAD_BYTES {
            return Err(PixelFrameError::InvalidPayloadLength {
                expected: FIXED_PIXEL_FRAME_PAYLOAD_BYTES,
                actual: payload.len(),
            });
        }
        Self::decode_body(&payload[1..])
    }

    /// Decodes a pixel frame from the body bytes (excluding the 1-byte marker).
    pub fn decode_body(body: &[u8]) -> Result<Self, PixelFrameError> {
        if body.len() != FIXED_PIXEL_FRAME_BODY_BYTES {
            return Err(PixelFrameError::InvalidPayloadLength {
                expected: FIXED_PIXEL_FRAME_BODY_BYTES,
                actual: body.len(),
            });
        }
        let layer_id = u32::from_be_bytes(body[0..4].try_into().unwrap());
        let count = u16::from_be_bytes(body[4..6].try_into().unwrap());
        if count != GEM80_TOTAL_LEDS as u16 {
            return Err(PixelFrameError::InvalidPixelCount {
                expected: GEM80_TOTAL_LEDS as u16,
                actual: count,
            });
        }
        let flags = body[6];
        let mut pixels = [0u8; GEM80_PIXEL_BUFFER_BYTES];
        pixels.copy_from_slice(&body[7..7 + GEM80_PIXEL_BUFFER_BYTES]);

        Ok(Self {
            layer_id: LayerId(layer_id),
            flags,
            pixels,
        })
    }
}

/// Reads a 4-byte big-endian length prefix and rejects empty and oversized frames.
fn decode_payload_len(len_bytes: [u8; LENGTH_PREFIX_WIDTH_BYTES]) -> Result<usize, FramingError> {
    let payload_len = u32::from_be_bytes(len_bytes) as usize;
    if payload_len == 0 {
        return Err(FramingError::EmptyFrame);
    }
    if payload_len > MAX_FRAME_PAYLOAD_BYTES {
        return Err(FramingError::OversizedFrame {
            size: payload_len,
            max: MAX_FRAME_PAYLOAD_BYTES,
        });
    }
    Ok(payload_len)
}

/// Encodes a framed message with a 4-byte big-endian length prefix and a 1-byte discriminator.
pub fn encode_frame(
    discriminator: WireMessageDiscriminator,
    body: &[u8],
) -> Result<Vec<u8>, FramingError> {
    let payload_len = 1 + body.len();
    if payload_len > MAX_FRAME_PAYLOAD_BYTES {
        return Err(FramingError::OversizedFrame {
            size: payload_len,
            max: MAX_FRAME_PAYLOAD_BYTES,
        });
    }
    let mut frame = Vec::with_capacity(LENGTH_PREFIX_WIDTH_BYTES + payload_len);
    frame.extend_from_slice(&(payload_len as u32).to_be_bytes());
    frame.push(discriminator as u8);
    frame.extend_from_slice(body);
    Ok(frame)
}

/// Decodes a framed message from a complete wire byte slice (including 4-byte length prefix).
pub fn decode_frame(frame_bytes: &[u8]) -> Result<(WireMessageDiscriminator, &[u8]), WireError> {
    if frame_bytes.len() < LENGTH_PREFIX_WIDTH_BYTES {
        return Err(FramingError::Truncated {
            expected: LENGTH_PREFIX_WIDTH_BYTES,
            actual: frame_bytes.len(),
        }
        .into());
    }
    let payload_len =
        decode_payload_len(frame_bytes[..LENGTH_PREFIX_WIDTH_BYTES].try_into().unwrap())?;
    let total_expected = LENGTH_PREFIX_WIDTH_BYTES + payload_len;
    if frame_bytes.len() < total_expected {
        return Err(FramingError::Truncated {
            expected: total_expected,
            actual: frame_bytes.len(),
        }
        .into());
    }
    let discriminator_byte = frame_bytes[LENGTH_PREFIX_WIDTH_BYTES];
    let discriminator = WireMessageDiscriminator::try_from(discriminator_byte)
        .map_err(FramingError::InvalidDiscriminator)?;
    let body = &frame_bytes[LENGTH_PREFIX_WIDTH_BYTES + 1..total_expected];
    Ok((discriminator, body))
}

/// Decodes payload bytes (discriminator + body) where the 4-byte length prefix was already consumed.
pub fn decode_payload(
    payload_bytes: &[u8],
) -> Result<(WireMessageDiscriminator, &[u8]), WireError> {
    if payload_bytes.is_empty() {
        return Err(FramingError::EmptyFrame.into());
    }
    let discriminator = WireMessageDiscriminator::try_from(payload_bytes[0])
        .map_err(FramingError::InvalidDiscriminator)?;
    Ok((discriminator, &payload_bytes[1..]))
}

/// Synchronously writes a framed message to a stream.
pub fn write_frame<W: Write>(
    writer: &mut W,
    discriminator: WireMessageDiscriminator,
    body: &[u8],
) -> Result<(), FramingError> {
    let frame = encode_frame(discriminator, body)?;
    writer
        .write_all(&frame)
        .map_err(|e| FramingError::Io(e.to_string()))?;
    Ok(())
}

/// Synchronously reads a framed message from a stream.
pub fn read_frame<R: Read>(
    reader: &mut R,
) -> Result<(WireMessageDiscriminator, Vec<u8>), FramingError> {
    match read_frame_optional(reader)? {
        Some(frame) => Ok(frame),
        None => Err(FramingError::Truncated {
            expected: LENGTH_PREFIX_WIDTH_BYTES,
            actual: 0,
        }),
    }
}

/// Whether an I/O error is a read timeout on a socket that carries one.
fn is_read_timeout(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    )
}

/// Reads a frame from a stream, returning `Ok(None)` cleanly on immediate EOF before any bytes are read.
///
/// A read timeout that arrives before the first byte of the length prefix is
/// reported as [`FramingError::IdleTimeout`], so a caller that bounds an idle
/// connection can tell "said nothing yet" from "stopped mid-frame".
pub fn read_frame_optional<R: Read>(
    reader: &mut R,
) -> Result<Option<(WireMessageDiscriminator, Vec<u8>)>, FramingError> {
    let mut len_buf = [0u8; LENGTH_PREFIX_WIDTH_BYTES];
    let mut read_bytes = 0;
    while read_bytes < LENGTH_PREFIX_WIDTH_BYTES {
        match reader.read(&mut len_buf[read_bytes..]) {
            Ok(0) => {
                if read_bytes == 0 {
                    return Ok(None);
                }
                return Err(FramingError::Truncated {
                    expected: LENGTH_PREFIX_WIDTH_BYTES,
                    actual: read_bytes,
                });
            }
            Ok(n) => read_bytes += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) if read_bytes == 0 && is_read_timeout(&e) => {
                return Err(FramingError::IdleTimeout)
            }
            Err(e) => return Err(FramingError::Io(e.to_string())),
        }
    }

    let payload_len = decode_payload_len(len_buf)?;

    let mut payload = vec![0u8; payload_len];
    let mut payload_read = 0;
    while payload_read < payload_len {
        match reader.read(&mut payload[payload_read..]) {
            Ok(0) => {
                return Err(FramingError::Truncated {
                    expected: payload_len,
                    actual: payload_read,
                });
            }
            Ok(n) => payload_read += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(FramingError::Io(e.to_string())),
        }
    }

    let discriminator = WireMessageDiscriminator::try_from(payload[0])
        .map_err(FramingError::InvalidDiscriminator)?;
    let body = payload[1..].to_vec();
    Ok(Some((discriminator, body)))
}

/// Buffer-based streaming frame decoder for handling coalesced and partial socket reads.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    /// Appends incoming stream bytes to the internal decoding buffer.
    pub fn push_bytes(&mut self, data: &[u8]) {
        self.buffer.extend_from_slice(data);
    }

    /// Attempts to extract the next complete frame from the internal buffer.
    pub fn next_frame(
        &mut self,
    ) -> Result<Option<(WireMessageDiscriminator, Vec<u8>)>, FramingError> {
        if self.buffer.len() < LENGTH_PREFIX_WIDTH_BYTES {
            return Ok(None);
        }
        let len_bytes: [u8; LENGTH_PREFIX_WIDTH_BYTES] =
            self.buffer[..LENGTH_PREFIX_WIDTH_BYTES].try_into().unwrap();
        let payload_len = decode_payload_len(len_bytes)?;
        let total_frame_len = LENGTH_PREFIX_WIDTH_BYTES + payload_len;
        if self.buffer.len() < total_frame_len {
            return Ok(None);
        }
        let discriminator_byte = self.buffer[LENGTH_PREFIX_WIDTH_BYTES];
        let discriminator = WireMessageDiscriminator::try_from(discriminator_byte)
            .map_err(FramingError::InvalidDiscriminator)?;
        let body = self.buffer[LENGTH_PREFIX_WIDTH_BYTES + 1..total_frame_len].to_vec();
        self.buffer.drain(..total_frame_len);
        Ok(Some((discriminator, body)))
    }

    /// Verifies that no partial/truncated frame remains unconsumed in the buffer at stream end.
    pub fn finish(&mut self) -> Result<(), FramingError> {
        if self.buffer.is_empty() {
            Ok(())
        } else if self.buffer.len() < LENGTH_PREFIX_WIDTH_BYTES {
            Err(FramingError::Truncated {
                expected: LENGTH_PREFIX_WIDTH_BYTES,
                actual: self.buffer.len(),
            })
        } else {
            let len_bytes: [u8; LENGTH_PREFIX_WIDTH_BYTES] =
                self.buffer[..LENGTH_PREFIX_WIDTH_BYTES].try_into().unwrap();
            let payload_len = u32::from_be_bytes(len_bytes) as usize;
            Err(FramingError::Truncated {
                expected: LENGTH_PREFIX_WIDTH_BYTES + payload_len,
                actual: self.buffer.len(),
            })
        }
    }
}

/// Encodes a `ClientMessage` into a framed wire byte buffer.
pub fn encode_client_frame(msg: &ClientMessage) -> Result<Vec<u8>, WireError> {
    let body = msg.encode_to_vec();
    encode_frame(WireMessageDiscriminator::Control, &body).map_err(WireError::Framing)
}

/// Decodes a `ClientMessage` from a framed wire byte slice.
pub fn decode_client_frame(frame_bytes: &[u8]) -> Result<ClientMessage, WireError> {
    let (discriminator, body) = decode_frame(frame_bytes)?;
    if discriminator != WireMessageDiscriminator::Control {
        return Err(WireError::DiscriminatorMismatch {
            expected: WireMessageDiscriminator::Control,
            actual: discriminator,
        });
    }
    ClientMessage::decode(body).map_err(WireError::ProtobufDecode)
}

/// Encodes a `ServerMessage` into a framed wire byte buffer.
pub fn encode_server_frame(msg: &ServerMessage) -> Result<Vec<u8>, WireError> {
    let body = msg.encode_to_vec();
    encode_frame(WireMessageDiscriminator::Control, &body).map_err(WireError::Framing)
}

/// Decodes a `ServerMessage` from a framed wire byte slice.
pub fn decode_server_frame(frame_bytes: &[u8]) -> Result<ServerMessage, WireError> {
    let (discriminator, body) = decode_frame(frame_bytes)?;
    if discriminator != WireMessageDiscriminator::Control {
        return Err(WireError::DiscriminatorMismatch {
            expected: WireMessageDiscriminator::Control,
            actual: discriminator,
        });
    }
    ServerMessage::decode(body).map_err(WireError::ProtobufDecode)
}

/// Encodes a `FixedPixelFrame` into a framed wire byte buffer.
pub fn encode_pixel_frame(frame: &FixedPixelFrame) -> Result<Vec<u8>, WireError> {
    let body = frame.encode_body();
    encode_frame(WireMessageDiscriminator::PixelFrame, &body).map_err(WireError::Framing)
}

/// Decodes a `FixedPixelFrame` from a framed wire byte slice.
pub fn decode_pixel_frame(frame_bytes: &[u8]) -> Result<FixedPixelFrame, WireError> {
    let (discriminator, body) = decode_frame(frame_bytes)?;
    if discriminator != WireMessageDiscriminator::PixelFrame {
        return Err(WireError::DiscriminatorMismatch {
            expected: WireMessageDiscriminator::PixelFrame,
            actual: discriminator,
        });
    }
    FixedPixelFrame::decode_body(body).map_err(WireError::PixelFrame)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_framing_round_trip() {
        let req = ClientMessage {
            request_id: 42,
            payload: Some(proto::client_message::Payload::RegisterLayer(
                RegisterLayerRequest {
                    name: "test-layer".to_string(),
                    z_order: 10,
                    lifetime_ms: Some(5000),
                    ..Default::default()
                },
            )),
        };

        let encoded = encode_client_frame(&req).expect("encoding client frame should succeed");
        assert!(!encoded.is_empty(), "encoded frame must not be empty");
        let decoded = decode_client_frame(&encoded).expect("decoding client frame should succeed");
        assert_eq!(req, decoded);

        // Server message round trip
        let resp = ServerMessage {
            request_id: 42,
            payload: Some(proto::server_message::Payload::RegisterLayer(
                RegisterLayerResponse { layer_id: 1 },
            )),
        };
        let encoded_resp =
            encode_server_frame(&resp).expect("encoding server frame should succeed");
        let decoded_resp =
            decode_server_frame(&encoded_resp).expect("decoding server frame should succeed");
        assert_eq!(resp, decoded_resp);

        // Pixel frame round trip
        let pixel_frame = FixedPixelFrame::new(LayerId(7), [0x55; GEM80_PIXEL_BUFFER_BYTES]);
        let encoded_pixel =
            encode_pixel_frame(&pixel_frame).expect("encoding pixel frame should succeed");
        let decoded_pixel =
            decode_pixel_frame(&encoded_pixel).expect("decoding pixel frame should succeed");
        assert_eq!(pixel_frame, decoded_pixel);
    }

    #[test]
    fn test_oversized_prefix_fails() {
        let mut decoder = FrameDecoder::new();
        let oversized_len = (MAX_FRAME_PAYLOAD_BYTES + 1) as u32;
        let mut frame = oversized_len.to_be_bytes().to_vec();
        frame.push(CONTROL_MESSAGE_MARKER);
        frame.extend_from_slice(&[0u8; 10]);

        decoder.push_bytes(&frame);
        let err = decoder
            .next_frame()
            .expect_err("oversized prefix must produce FramingError");
        assert_eq!(
            err,
            FramingError::OversizedFrame {
                size: MAX_FRAME_PAYLOAD_BYTES + 1,
                max: MAX_FRAME_PAYLOAD_BYTES,
            }
        );
    }

    #[test]
    fn test_truncated_stream_fails() {
        let mut decoder = FrameDecoder::new();
        let declared_len = 100u32;
        let mut frame = declared_len.to_be_bytes().to_vec();
        frame.push(CONTROL_MESSAGE_MARKER);
        frame.extend_from_slice(&[0u8; 10]); // Only 11 payload bytes provided of 100

        decoder.push_bytes(&frame);
        assert_eq!(decoder.next_frame().unwrap(), None);
        let err = decoder
            .finish()
            .expect_err("truncated stream on finish must fail");
        assert_eq!(
            err,
            FramingError::Truncated {
                expected: 104,
                actual: 15,
            }
        );
    }

    #[test]
    fn test_coalesced_messages_decoded_in_order() {
        let mut decoder = FrameDecoder::new();
        let msg1 = ClientMessage {
            request_id: 1,
            payload: Some(proto::client_message::Payload::ReleaseLayer(
                ReleaseLayerRequest { layer_id: 10 },
            )),
        };
        let msg2 = ClientMessage {
            request_id: 2,
            payload: Some(proto::client_message::Payload::ReleaseLayer(
                ReleaseLayerRequest { layer_id: 20 },
            )),
        };

        let mut coalesced = encode_client_frame(&msg1).unwrap();
        coalesced.extend_from_slice(&encode_client_frame(&msg2).unwrap());

        decoder.push_bytes(&coalesced);
        let decoded1 = decoder
            .next_frame()
            .unwrap()
            .expect("first message should decode");
        let decoded2 = decoder
            .next_frame()
            .unwrap()
            .expect("second message should decode");
        assert_eq!(decoder.next_frame().unwrap(), None);

        assert_eq!(decoded1.0, WireMessageDiscriminator::Control);
        assert_eq!(decoded2.0, WireMessageDiscriminator::Control);
        let parsed1 = ClientMessage::decode(decoded1.1.as_slice()).unwrap();
        let parsed2 = ClientMessage::decode(decoded2.1.as_slice()).unwrap();
        assert_eq!(parsed1.request_id, 1);
        assert_eq!(parsed2.request_id, 2);
    }

    #[test]
    fn test_unimplemented_fields_decode_successfully() {
        let req = ClientMessage {
            request_id: 99,
            payload: Some(proto::client_message::Payload::RegisterLayer(
                RegisterLayerRequest {
                    name: "future-features".to_string(),
                    z_order: 5,
                    lifetime_ms: Some(1000),
                    blend_mode: Some(BlendMode::Alpha as i32),
                    opacity: Some(0.75),
                    push_fps: Some(60),
                },
            )),
        };

        let encoded = encode_client_frame(&req).unwrap();
        let decoded = decode_client_frame(&encoded)
            .expect("v1 unimplemented fields must decode successfully");
        assert_eq!(req, decoded);
    }

    #[test]
    fn test_discriminator_distinguishes_control_and_pixel_frame() {
        let control_msg = ClientMessage {
            request_id: 1,
            payload: Some(proto::client_message::Payload::GetStatus(
                GetStatusRequest {
                    include_layers: true,
                    include_composite_frame: false,
                },
            )),
        };
        let control_frame = encode_client_frame(&control_msg).unwrap();

        let pixel_frame = FixedPixelFrame::new(LayerId(5), [0xAA; GEM80_PIXEL_BUFFER_BYTES]);
        let pixel_bytes = encode_pixel_frame(&pixel_frame).unwrap();

        let decode_pixel_from_control = decode_pixel_frame(&control_frame);
        assert!(
            decode_pixel_from_control.is_err(),
            "decoding pixel frame from control bytes must fail"
        );
        match decode_pixel_from_control.unwrap_err() {
            WireError::DiscriminatorMismatch { expected, actual } => {
                assert_eq!(expected, WireMessageDiscriminator::PixelFrame);
                assert_eq!(actual, WireMessageDiscriminator::Control);
            }
            other => panic!("expected DiscriminatorMismatch, got {:?}", other),
        }

        let decode_control_from_pixel = decode_client_frame(&pixel_bytes);
        assert!(
            decode_control_from_pixel.is_err(),
            "decoding control message from pixel frame bytes must fail"
        );
        match decode_control_from_pixel.unwrap_err() {
            WireError::DiscriminatorMismatch { expected, actual } => {
                assert_eq!(expected, WireMessageDiscriminator::Control);
                assert_eq!(actual, WireMessageDiscriminator::PixelFrame);
            }
            other => panic!("expected DiscriminatorMismatch, got {:?}", other),
        }
    }

    #[test]
    fn test_pixel_retraction_r24_in_wire_protocol() {
        let update_req = ClientMessage {
            request_id: 10,
            payload: Some(proto::client_message::Payload::UpdateLayer(
                UpdateLayerRequest {
                    layer_id: 3,
                    set_pixels: vec![LedColor {
                        led_index: 0,
                        red: 255,
                        green: 0,
                        blue: 0,
                    }],
                    retract_leds: vec![1, 2, 3], // R24: retract LEDs 1, 2, 3 so lower layers show
                },
            )),
        };

        let encoded = encode_client_frame(&update_req).unwrap();
        let decoded = decode_client_frame(&encoded).unwrap();
        assert_eq!(update_req, decoded);

        // Dedicated retract request
        let retract_req = ClientMessage {
            request_id: 11,
            payload: Some(proto::client_message::Payload::RetractPixels(
                RetractPixelsRequest {
                    layer_id: 3,
                    led_indices: vec![4, 5, 6],
                },
            )),
        };
        let encoded_retract = encode_client_frame(&retract_req).unwrap();
        let decoded_retract = decode_client_frame(&encoded_retract).unwrap();
        assert_eq!(retract_req, decoded_retract);
    }

    #[test]
    fn test_synchronous_read_write_frame() {
        let mut buffer = Vec::new();
        let data = b"hello wire protocol";
        write_frame(&mut buffer, WireMessageDiscriminator::Control, data).unwrap();

        let mut cursor = std::io::Cursor::new(buffer);
        let (disc, body) = read_frame(&mut cursor).unwrap();
        assert_eq!(disc, WireMessageDiscriminator::Control);
        assert_eq!(body, data);
    }

    #[test]
    fn test_empty_frame_fails() {
        let mut decoder = FrameDecoder::new();
        let zero_len = 0u32.to_be_bytes();
        decoder.push_bytes(&zero_len);
        let err = decoder.next_frame().expect_err("0-length frame must fail");
        assert_eq!(err, FramingError::EmptyFrame);
    }

    #[test]
    fn test_invalid_discriminator_fails() {
        let mut decoder = FrameDecoder::new();
        let len = 5u32.to_be_bytes();
        decoder.push_bytes(&len);
        decoder.push_bytes(&[0xEE, 1, 2, 3, 4]); // 0xEE is not a valid discriminator
        let err = decoder
            .next_frame()
            .expect_err("unknown discriminator must fail");
        assert_eq!(err, FramingError::InvalidDiscriminator(0xEE));
    }

    #[test]
    fn test_read_frame_truncated_stream() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&50u32.to_be_bytes());
        buf.push(CONTROL_MESSAGE_MARKER);
        buf.extend_from_slice(&[1, 2, 3]); // only 4 bytes of 50
        let mut cursor = std::io::Cursor::new(buf);
        let err = read_frame(&mut cursor).expect_err("truncated stream in read_frame must fail");
        assert_eq!(
            err,
            FramingError::Truncated {
                expected: 50,
                actual: 4
            }
        );
    }

    #[test]
    fn test_read_frame_optional_clean_eof() {
        let mut cursor = std::io::Cursor::new(Vec::new());
        let res = read_frame_optional(&mut cursor).expect("clean EOF should succeed with None");
        assert_eq!(res, None);
    }

    #[test]
    fn test_pixel_frame_validation() {
        // Invalid length
        let err = FixedPixelFrame::decode(&[PIXEL_FRAME_MARKER, 1, 2, 3]).unwrap_err();
        assert_eq!(
            err,
            PixelFrameError::InvalidPayloadLength {
                expected: FIXED_PIXEL_FRAME_PAYLOAD_BYTES,
                actual: 4,
            }
        );

        // Invalid LED count
        let mut bad_body = vec![0u8; FIXED_PIXEL_FRAME_BODY_BYTES];
        bad_body[0..4].copy_from_slice(&1u32.to_be_bytes());
        bad_body[4..6].copy_from_slice(&50u16.to_be_bytes()); // 50 instead of 101
        let err_count = FixedPixelFrame::decode_body(&bad_body).unwrap_err();
        assert_eq!(
            err_count,
            PixelFrameError::InvalidPixelCount {
                expected: GEM80_TOTAL_LEDS as u16,
                actual: 50,
            }
        );
    }
}
