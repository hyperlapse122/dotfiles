//! Layer model, z-ordering, and diff compositor for 101 Gem80 LEDs.
//!
//! Pure computation and state management:
//! - Z-ordering and registration sequence tie-breaking (R7, R11).
//! - Base layer at lowest z (R8).
//! - Sparse pixel mapping and pixel retraction (R14, R24).
//! - Hardware mirror tracking and full invalidation (R9, R23, KTD3).
//! - Tick-driven layer lifetime expiration (R10).

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use crate::wire::{
    CompositeZIndex, ConnectionId, LayerId, LayerSummary, GEM80_PIXEL_BUFFER_BYTES,
    GEM80_TOTAL_LEDS,
};

/// Reserved LayerId for the daemon-owned base layer.
pub const BASE_LAYER_ID: LayerId = LayerId(0);

/// Reserved Z-index for the daemon-owned base layer (lowest possible z).
pub const BASE_LAYER_Z: CompositeZIndex = CompositeZIndex(i32::MIN);

/// Default fallback base color for all 101 LEDs: soft warm white (not off / not black, R8).
pub const DEFAULT_BASE_COLOR: Color = Color {
    r: 180,
    g: 180,
    b: 180,
};

/// 24-bit RGB color for an individual keyboard LED.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, Default, serde::Serialize, serde::Deserialize,
)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Color {
    /// Black color (LED completely unlit / off).
    pub const BLACK: Self = Self { r: 0, g: 0, b: 0 };

    /// Full white color.
    pub const WHITE: Self = Self {
        r: 255,
        g: 255,
        b: 255,
    };

    /// Creates a new RGB color.
    pub const fn new(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }

    /// Creates a new RGB color (alias for `new`).
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }

    /// Converts color into 3-byte `[r, g, b]` array.
    pub const fn to_bytes(self) -> [u8; 3] {
        [self.r, self.g, self.b]
    }

    /// Constructs color from 3-byte `[r, g, b]` array.
    pub const fn from_bytes(bytes: [u8; 3]) -> Self {
        Self {
            r: bytes[0],
            g: bytes[1],
            b: bytes[2],
        }
    }
}

impl From<[u8; 3]> for Color {
    fn from(bytes: [u8; 3]) -> Self {
        Self::from_bytes(bytes)
    }
}

impl From<Color> for [u8; 3] {
    fn from(color: Color) -> Self {
        color.to_bytes()
    }
}

impl From<(u8, u8, u8)> for Color {
    fn from((r, g, b): (u8, u8, u8)) -> Self {
        Self::new(r, g, b)
    }
}

impl From<crate::wire::LedColor> for (usize, Color) {
    fn from(c: crate::wire::LedColor) -> Self {
        (
            c.led_index as usize,
            Color::new(c.red as u8, c.green as u8, c.blue as u8),
        )
    }
}

impl From<(usize, Color)> for crate::wire::LedColor {
    fn from((led_index, color): (usize, Color)) -> Self {
        crate::wire::LedColor {
            led_index: led_index as u32,
            red: color.r as u32,
            green: color.g as u32,
            blue: color.b as u32,
        }
    }
}

/// A single modified LED in a differential frame update.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LedDiff {
    /// Zero-based LED index (0..101).
    pub led_index: usize,
    /// New RGB color to paint.
    pub color: Color,
}

impl From<LedDiff> for crate::wire::LedColor {
    fn from(diff: LedDiff) -> Self {
        crate::wire::LedColor {
            led_index: diff.led_index as u32,
            red: diff.color.r as u32,
            green: diff.color.g as u32,
            blue: diff.color.b as u32,
        }
    }
}

/// Errors produced during compositor operations.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CompositorError {
    #[error("invalid LED index: {0} (must be < {GEM80_TOTAL_LEDS})")]
    InvalidLedIndex(usize),

    #[error("layer not found: {0:?}")]
    LayerNotFound(LayerId),

    #[error("cannot remove or replace reserved base layer")]
    BaseLayerImmutable,

    #[error("layer already exists: {0:?}")]
    LayerAlreadyExists(LayerId),
}

/// An individual compositing layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layer {
    /// Unique identifier for this layer.
    pub id: LayerId,
    /// Diagnostic name (e.g. "fcitx5-status", "volume-level").
    pub name: String,
    /// Owning connection ID (`None` for daemon-owned layers like base layer).
    pub owner: Option<ConnectionId>,
    /// Z-order: higher sits on top of lower (R7).
    pub z_order: CompositeZIndex,
    /// Monotonic registration sequence for breaking z-order ties (R7).
    pub registration_sequence: u64,
    /// Remaining lifetime before automatic expiration (R10).
    pub remaining_lifetime: Option<Duration>,
    /// Sparse pixel map: maps LED index (0..101) to RGB color (R14).
    pub pixels: BTreeMap<usize, Color>,
}

impl Layer {
    /// Creates a new layer.
    pub fn new(
        id: LayerId,
        name: impl Into<String>,
        owner: Option<ConnectionId>,
        z_order: CompositeZIndex,
        registration_sequence: u64,
        lifetime: Option<Duration>,
    ) -> Self {
        Self {
            id,
            name: name.into(),
            owner,
            z_order,
            registration_sequence,
            remaining_lifetime: lifetime,
            pixels: BTreeMap::new(),
        }
    }

    /// Sets an individual LED color.
    pub fn set_pixel(&mut self, led_index: usize, color: Color) -> Result<(), CompositorError> {
        if led_index >= GEM80_TOTAL_LEDS {
            return Err(CompositorError::InvalidLedIndex(led_index));
        }
        self.pixels.insert(led_index, color);
        Ok(())
    }

    /// Retracts an individual LED color so lower layers show through (R24).
    pub fn retract_pixel(&mut self, led_index: usize) -> Result<Option<Color>, CompositorError> {
        if led_index >= GEM80_TOTAL_LEDS {
            return Err(CompositorError::InvalidLedIndex(led_index));
        }
        Ok(self.pixels.remove(&led_index))
    }

    /// Number of painted pixels in this sparse layer.
    pub fn pixel_count(&self) -> usize {
        self.pixels.len()
    }

    /// Clears all painted pixels from this layer.
    pub fn clear_pixels(&mut self) {
        self.pixels.clear();
    }
}

/// The Gem80 multi-layer LED compositor and hardware mirror.
#[derive(Debug, Clone)]
pub struct Compositor {
    /// Daemon-owned base layer sitting at z = i32::MIN (R8).
    base_layer: Layer,
    /// Active client-registered layers.
    layers: HashMap<LayerId, Layer>,
    /// Mirror of what is currently painted on hardware.
    hardware_mirror: [Color; GEM80_TOTAL_LEDS],
    /// True if the hardware mirror is in sync with keyboard device state.
    /// Invalidation (KTD3, R23) forces the next diff calculation to yield all 101 LEDs.
    mirror_valid: bool,
    /// Strictly monotonic sequence number for registration tie-breaking (R7).
    next_sequence: u64,
    /// Next layer ID allocator.
    next_layer_id: u32,
    /// Last recorded tick instant for measuring elapsed time.
    last_tick: Option<Instant>,
}

impl Default for Compositor {
    fn default() -> Self {
        Self::new()
    }
}

impl Compositor {
    /// Creates a new compositor initialized with the default base color (R8).
    pub fn new() -> Self {
        Self::with_base_color(DEFAULT_BASE_COLOR)
    }

    /// Creates a new compositor with a uniform base color across all 101 LEDs.
    pub fn with_base_color(base_color: Color) -> Self {
        let mut base_layer = Layer::new(BASE_LAYER_ID, "base", None, BASE_LAYER_Z, 0, None);
        for led in 0..GEM80_TOTAL_LEDS {
            base_layer.pixels.insert(led, base_color);
        }

        Self {
            base_layer,
            layers: HashMap::new(),
            hardware_mirror: [Color::BLACK; GEM80_TOTAL_LEDS],
            mirror_valid: false,
            next_sequence: 1,
            next_layer_id: 1,
            last_tick: None,
        }
    }

    /// Returns a reference to the daemon-owned base layer.
    pub fn base_layer(&self) -> &Layer {
        &self.base_layer
    }

    /// Returns a mutable reference to the daemon-owned base layer.
    pub fn base_layer_mut(&mut self) -> &mut Layer {
        &mut self.base_layer
    }

    /// Sets the base color uniformly across all 101 LEDs.
    pub fn set_base_color(&mut self, color: Color) {
        for led in 0..GEM80_TOTAL_LEDS {
            self.base_layer.pixels.insert(led, color);
        }
    }

    /// Sets specific pixels on the base layer.
    pub fn set_base_pixels(
        &mut self,
        pixels: impl IntoIterator<Item = (usize, Color)>,
    ) -> Result<(), CompositorError> {
        for (led, color) in pixels {
            self.base_layer.set_pixel(led, color)?;
        }
        Ok(())
    }

    /// Allocates and registers a new compositing layer.
    pub fn register_layer(
        &mut self,
        owner: Option<ConnectionId>,
        name: impl Into<String>,
        z_order: CompositeZIndex,
        lifetime: Option<Duration>,
    ) -> LayerId {
        let id = LayerId(self.next_layer_id);
        self.next_layer_id = self
            .next_layer_id
            .checked_add(1)
            .expect("layer ID overflow");

        let seq = self.next_sequence;
        self.next_sequence = self
            .next_sequence
            .checked_add(1)
            .expect("sequence counter overflow");

        let layer = Layer::new(id, name, owner, z_order, seq, lifetime);
        self.layers.insert(id, layer);
        id
    }

    /// Registers a layer with an explicitly supplied layer ID (used during state reload).
    pub fn register_layer_with_id(
        &mut self,
        id: LayerId,
        owner: Option<ConnectionId>,
        name: impl Into<String>,
        z_order: CompositeZIndex,
        lifetime: Option<Duration>,
    ) -> Result<(), CompositorError> {
        if id == BASE_LAYER_ID {
            return Err(CompositorError::BaseLayerImmutable);
        }
        if self.layers.contains_key(&id) {
            return Err(CompositorError::LayerAlreadyExists(id));
        }

        let seq = self.next_sequence;
        self.next_sequence = self
            .next_sequence
            .checked_add(1)
            .expect("sequence counter overflow");

        if id.0 >= self.next_layer_id {
            self.next_layer_id = id.0.saturating_add(1);
        }

        let layer = Layer::new(id, name, owner, z_order, seq, lifetime);
        self.layers.insert(id, layer);
        Ok(())
    }

    /// Removes a layer by its ID.
    pub fn remove_layer(&mut self, id: LayerId) -> Result<Layer, CompositorError> {
        if id == BASE_LAYER_ID {
            return Err(CompositorError::BaseLayerImmutable);
        }
        self.layers
            .remove(&id)
            .ok_or(CompositorError::LayerNotFound(id))
    }

    /// Removes all layers belonging to a specific client connection (R13, AE2).
    pub fn remove_connection_layers(&mut self, connection: ConnectionId) -> Vec<LayerId> {
        let mut removed = Vec::new();
        self.layers.retain(|&id, layer| {
            if layer.owner == Some(connection) {
                removed.push(id);
                false
            } else {
                true
            }
        });
        removed.sort();
        removed
    }

    /// Returns a reference to a layer by ID (including base layer).
    pub fn get_layer(&self, id: LayerId) -> Option<&Layer> {
        if id == BASE_LAYER_ID {
            Some(&self.base_layer)
        } else {
            self.layers.get(&id)
        }
    }

    /// Returns a mutable reference to a layer by ID (including base layer).
    pub fn get_layer_mut(&mut self, id: LayerId) -> Option<&mut Layer> {
        if id == BASE_LAYER_ID {
            Some(&mut self.base_layer)
        } else {
            self.layers.get_mut(&id)
        }
    }

    /// Returns true if a layer exists.
    pub fn has_layer(&self, id: LayerId) -> bool {
        id == BASE_LAYER_ID || self.layers.contains_key(&id)
    }

    /// Count of active client layers (excluding base layer).
    pub fn layer_count(&self) -> usize {
        self.layers.len()
    }

    /// Sets a pixel on an existing layer (R14).
    pub fn set_pixel(
        &mut self,
        id: LayerId,
        led_index: usize,
        color: Color,
    ) -> Result<(), CompositorError> {
        let layer = self
            .get_layer_mut(id)
            .ok_or(CompositorError::LayerNotFound(id))?;
        layer.set_pixel(led_index, color)
    }

    /// Retracts a pixel on an existing layer (R24).
    pub fn retract_pixel(&mut self, id: LayerId, led_index: usize) -> Result<(), CompositorError> {
        let layer = self
            .get_layer_mut(id)
            .ok_or(CompositorError::LayerNotFound(id))?;
        layer.retract_pixel(led_index)?;
        Ok(())
    }

    /// Retracts multiple pixels on an existing layer (R24).
    pub fn retract_pixels(
        &mut self,
        id: LayerId,
        leds: impl IntoIterator<Item = usize>,
    ) -> Result<(), CompositorError> {
        let layer = self
            .get_layer_mut(id)
            .ok_or(CompositorError::LayerNotFound(id))?;
        for led in leds {
            layer.retract_pixel(led)?;
        }
        Ok(())
    }

    /// Updates an existing layer with sparse pixel writes and pixel retractions (R14, R24).
    pub fn update_layer(
        &mut self,
        id: LayerId,
        set_pixels: impl IntoIterator<Item = (usize, Color)>,
        retract_leds: impl IntoIterator<Item = usize>,
    ) -> Result<(), CompositorError> {
        let layer = self
            .get_layer_mut(id)
            .ok_or(CompositorError::LayerNotFound(id))?;
        for (led, color) in set_pixels {
            layer.set_pixel(led, color)?;
        }
        for led in retract_leds {
            layer.retract_pixel(led)?;
        }
        Ok(())
    }

    /// Generates summary metadata for all registered client layers (for R20 status inspection).
    pub fn layer_summaries(&self) -> Vec<LayerSummary> {
        let mut summaries: Vec<_> = self
            .layers
            .values()
            .map(|layer| LayerSummary {
                layer_id: layer.id.0,
                name: layer.name.clone(),
                z_order: layer.z_order.0,
                pixel_count: layer.pixel_count() as u32,
                remaining_lifetime_ms: layer
                    .remaining_lifetime
                    .map(|d| d.as_millis().min(u32::MAX as u128) as u32),
            })
            .collect();
        summaries.sort_by_key(|s| (s.z_order, s.layer_id));
        summaries
    }

    /// Composes all layers in z-order ascending, breaking ties by registration sequence (R7, R11).
    ///
    /// The base layer sits at lowest z (i32::MIN) and registration sequence 0 (R8).
    /// Returns the complete 101-LED color buffer.
    pub fn compose(&self) -> [Color; GEM80_TOTAL_LEDS] {
        // Collect all layers: base_layer plus all client layers
        let mut ordered_layers: Vec<&Layer> = Vec::with_capacity(1 + self.layers.len());
        ordered_layers.push(&self.base_layer);
        ordered_layers.extend(self.layers.values());

        // Sort by (z_order, registration_sequence) ascending.
        // Higher z renders later, overwriting lower z (R11).
        // For equal z, later registration sequence renders later, winning ties (R7).
        ordered_layers.sort_by_key(|layer| (layer.z_order.0, layer.registration_sequence));

        let mut frame = [Color::BLACK; GEM80_TOTAL_LEDS];
        for layer in ordered_layers {
            for (&led, &color) in &layer.pixels {
                if led < GEM80_TOTAL_LEDS {
                    frame[led] = color;
                }
            }
        }
        frame
    }

    /// Composes all layers into raw RGB bytes (303 bytes for 101 LEDs).
    pub fn compose_bytes(&self) -> [u8; GEM80_PIXEL_BUFFER_BYTES] {
        let frame = self.compose();
        let mut bytes = [0u8; GEM80_PIXEL_BUFFER_BYTES];
        for (i, color) in frame.iter().enumerate() {
            let offset = i * 3;
            bytes[offset] = color.r;
            bytes[offset + 1] = color.g;
            bytes[offset + 2] = color.b;
        }
        bytes
    }

    /// Invalidates the hardware mirror (KTD3, R23).
    ///
    /// Called on direct mode entry/re-entry, write failures, or communication timeouts.
    /// The subsequent `compose_diff` call will emit all 101 LEDs unconditionally.
    pub fn invalidate_mirror(&mut self) {
        self.mirror_valid = false;
    }

    /// Returns whether the hardware mirror is currently valid.
    pub fn is_mirror_valid(&self) -> bool {
        self.mirror_valid
    }

    /// Returns the currently tracked hardware mirror colors, if valid.
    pub fn hardware_mirror(&self) -> Option<&[Color; GEM80_TOTAL_LEDS]> {
        if self.mirror_valid {
            Some(&self.hardware_mirror)
        } else {
            None
        }
    }

    /// Commits a frame to the hardware mirror, marking the mirror valid.
    pub fn commit_frame(&mut self, frame: [Color; GEM80_TOTAL_LEDS]) {
        self.hardware_mirror = frame;
        self.mirror_valid = true;
    }

    /// Calculates differential LEDs between the given frame and the hardware mirror.
    ///
    /// If the hardware mirror is invalid, returns all 101 LEDs (KTD3, AE3, AE13).
    /// Otherwise returns only the LEDs whose color differs from the mirror (R9, AE8).
    pub fn diff_against_mirror(&self, frame: &[Color; GEM80_TOTAL_LEDS]) -> Vec<LedDiff> {
        let mut diff = Vec::new();
        if !self.mirror_valid {
            diff.reserve(GEM80_TOTAL_LEDS);
            for (i, &color) in frame.iter().enumerate() {
                diff.push(LedDiff {
                    led_index: i,
                    color,
                });
            }
        } else {
            for (i, &color) in frame.iter().enumerate() {
                if self.hardware_mirror[i] != color {
                    diff.push(LedDiff {
                        led_index: i,
                        color,
                    });
                }
            }
        }
        diff
    }

    /// Composes the current frame, calculates the diff against the hardware mirror,
    /// and automatically updates the mirror to the newly composed frame.
    ///
    /// If the mirror was invalid, the returned diff contains all 101 LEDs (AE3, AE13).
    /// If only 1 LED changed, the returned diff contains exactly 1 LED (AE8).
    pub fn compose_diff(&mut self) -> Vec<LedDiff> {
        let frame = self.compose();
        let diff = self.diff_against_mirror(&frame);
        self.commit_frame(frame);
        diff
    }

    /// Advances compositor time by `elapsed` duration, expiring layers whose lifetime has ended (R10).
    ///
    /// Returns the IDs of all layers that expired and were removed in this tick.
    pub fn tick_elapsed(&mut self, elapsed: Duration) -> Vec<LayerId> {
        let mut expired = Vec::new();
        for (&id, layer) in &mut self.layers {
            if let Some(remaining) = layer.remaining_lifetime.as_mut() {
                if *remaining <= elapsed {
                    expired.push(id);
                } else {
                    *remaining -= elapsed;
                }
            }
        }

        for &id in &expired {
            self.layers.remove(&id);
        }
        expired.sort();
        expired
    }

    /// Advances compositor time to `now`, computing elapsed duration from the previous tick.
    pub fn tick_at(&mut self, now: Instant) -> Vec<LayerId> {
        let elapsed = if let Some(last) = self.last_tick {
            now.saturating_duration_since(last)
        } else {
            Duration::ZERO
        };
        self.last_tick = Some(now);
        self.tick_elapsed(elapsed)
    }

    /// Standard tick handler using real time.
    pub fn tick(&mut self) -> Vec<LayerId> {
        self.tick_at(Instant::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test scenario: 레이어가 하나도 없으면 결과가 베이스 레이어와 같다. Covers AE1.
    #[test]
    fn test_empty_layers_result_equals_base_layer_ae1() {
        let base_color = Color::rgb(100, 150, 200);
        let compositor = Compositor::with_base_color(base_color);

        assert_eq!(compositor.layer_count(), 0);
        let frame = compositor.compose();

        assert_eq!(frame.len(), GEM80_TOTAL_LEDS);
        for &color in &frame {
            assert_eq!(color, base_color);
            assert_ne!(color, Color::BLACK); // Not off / not black (R8)
        }
    }

    /// Test scenario: 위 레이어가 같은 LED를 칠하면 그 색이 이긴다. (Higher z-order wins, R11)
    #[test]
    fn test_higher_z_order_layer_wins_r11() {
        let mut compositor = Compositor::with_base_color(Color::BLACK);

        let red = Color::rgb(255, 0, 0);
        let blue = Color::rgb(0, 0, 255);

        // Layer 1 at z = 10 paints LED 5 Red
        let l1 = compositor.register_layer(None, "lower", CompositeZIndex(10), None);
        compositor.set_pixel(l1, 5, red).unwrap();

        // Layer 2 at z = 20 paints LED 5 Blue
        let l2 = compositor.register_layer(None, "higher", CompositeZIndex(20), None);
        compositor.set_pixel(l2, 5, blue).unwrap();

        let frame = compositor.compose();
        assert_eq!(frame[5], blue);
    }

    /// Test scenario: 같은 z를 가진 두 레이어는 등록이 늦은 쪽이 이긴다. (Tie-breaking by sequence, R7)
    #[test]
    fn test_equal_z_order_later_registration_wins_r7() {
        let mut compositor = Compositor::with_base_color(Color::BLACK);

        let green = Color::rgb(0, 255, 0);
        let yellow = Color::rgb(255, 255, 0);

        // First registered at z = 5 paints LED 42 Green
        let l1 = compositor.register_layer(None, "first", CompositeZIndex(5), None);
        compositor.set_pixel(l1, 42, green).unwrap();

        // Second registered at same z = 5 paints LED 42 Yellow
        let l2 = compositor.register_layer(None, "second", CompositeZIndex(5), None);
        compositor.set_pixel(l2, 42, yellow).unwrap();

        let frame = compositor.compose();
        assert_eq!(frame[42], yellow);
    }

    /// Test scenario: 레이어를 제거하면 그 LED가 아래 레이어의 색으로 돌아간다. Covers AE2.
    #[test]
    fn test_remove_layer_restores_lower_color_ae2() {
        let base_color = Color::rgb(30, 30, 30);
        let mut compositor = Compositor::with_base_color(base_color);

        let conn = ConnectionId(1234);
        let cyan = Color::rgb(0, 255, 255);

        let layer = compositor.register_layer(Some(conn), "app", CompositeZIndex(1), None);
        compositor.set_pixel(layer, 10, cyan).unwrap();

        // While layer is active, LED 10 is cyan
        assert_eq!(compositor.compose()[10], cyan);

        // Client disconnects or layer is removed (AE2)
        let removed = compositor.remove_connection_layers(conn);
        assert_eq!(removed, vec![layer]);

        // LED 10 reverts to base color
        assert_eq!(compositor.compose()[10], base_color);
    }

    /// Test scenario: 레이어에서 한 LED만 거두면 그 LED가 아래 레이어의 색으로 돌아가고,
    /// 검정을 칠한 경우와 결과가 다르다. Covers AE17, R24.
    #[test]
    fn test_pixel_retraction_differs_from_painting_black_ae17_r24() {
        let base_color = Color::rgb(120, 80, 40);
        let mut compositor = Compositor::with_base_color(base_color);

        let magenta = Color::rgb(255, 0, 255);
        let layer = compositor.register_layer(None, "test", CompositeZIndex(10), None);

        // Paint LED 7 magenta
        compositor.set_pixel(layer, 7, magenta).unwrap();
        assert_eq!(compositor.compose()[7], magenta);

        // Case A: Paint black explicitly on layer
        compositor.set_pixel(layer, 7, Color::BLACK).unwrap();
        let frame_black = compositor.compose();
        assert_eq!(frame_black[7], Color::BLACK);
        assert_ne!(frame_black[7], base_color); // Black hides the base layer!

        // Case B: Retract the pixel (R24)
        compositor.retract_pixel(layer, 7).unwrap();
        let frame_retracted = compositor.compose();
        assert_eq!(frame_retracted[7], base_color); // Retracting reveals the lower layer!
        assert_ne!(frame_retracted[7], Color::BLACK);
    }

    /// Test scenario: 한 LED만 바뀐 갱신 뒤의 차등 결과가 정확히 1개다. Covers AE8.
    #[test]
    fn test_single_led_update_diff_count_is_one_ae8() {
        let mut compositor = Compositor::with_base_color(Color::rgb(10, 10, 10));

        // Initial diff against uninitialized mirror outputs all 101 LEDs
        let initial_diff = compositor.compose_diff();
        assert_eq!(initial_diff.len(), GEM80_TOTAL_LEDS);
        assert!(compositor.is_mirror_valid());

        // Without any changes, diff is 0
        let no_change_diff = compositor.compose_diff();
        assert_eq!(no_change_diff.len(), 0);

        // Update exactly one LED
        let layer = compositor.register_layer(None, "status", CompositeZIndex(1), None);
        let orange = Color::rgb(255, 128, 0);
        compositor.set_pixel(layer, 50, orange).unwrap();

        // Diff after one LED update must be exactly 1 LED (AE8)
        let diff = compositor.compose_diff();
        assert_eq!(diff.len(), 1);
        assert_eq!(diff[0].led_index, 50);
        assert_eq!(diff[0].color, orange);

        // Next compose has 0 diff
        assert_eq!(compositor.compose_diff().len(), 0);
    }

    /// Test scenario: 미러를 무효화한 뒤의 차등 결과가 101개다. Covers AE3, AE13.
    #[test]
    fn test_invalidate_mirror_forces_full_101_led_diff_ae3_ae13() {
        let mut compositor = Compositor::with_base_color(Color::rgb(20, 20, 20));

        // Initial diff populates mirror
        let diff1 = compositor.compose_diff();
        assert_eq!(diff1.len(), 101);
        assert!(compositor.is_mirror_valid());

        // Normal subsequent diff is 0
        let diff2 = compositor.compose_diff();
        assert_eq!(diff2.len(), 0);

        // Hardware mirror invalidated due to write failure or heartbeat rejection (KTD3, R23)
        compositor.invalidate_mirror();
        assert!(!compositor.is_mirror_valid());

        // Next diff must yield all 101 LEDs even if no layer changed! (AE3, AE13)
        let diff3 = compositor.compose_diff();
        assert_eq!(diff3.len(), 101);
        assert!(compositor.is_mirror_valid());

        // Verify index ordering 0..101
        for (i, item) in diff3.iter().enumerate() {
            assert_eq!(item.led_index, i);
        }
    }

    /// Test scenario: 수명이 지난 레이어는 tick에서 사라진다. Covers AE10.
    #[test]
    fn test_expired_layer_removed_on_tick_ae10() {
        let base_color = Color::rgb(5, 5, 5);
        let mut compositor = Compositor::with_base_color(base_color);

        let purple = Color::rgb(180, 0, 255);
        // Layer with 100ms lifetime
        let layer = compositor.register_layer(
            None,
            "toast",
            CompositeZIndex(10),
            Some(Duration::from_millis(100)),
        );
        compositor.set_pixel(layer, 80, purple).unwrap();
        assert_eq!(compositor.compose()[80], purple);

        // Advance by 50ms - layer should still be alive
        let expired = compositor.tick_elapsed(Duration::from_millis(50));
        assert!(expired.is_empty());
        assert!(compositor.has_layer(layer));
        assert_eq!(compositor.compose()[80], purple);

        // Advance by another 60ms (total 110ms > 100ms) - layer expires (AE10)
        let expired = compositor.tick_elapsed(Duration::from_millis(60));
        assert_eq!(expired, vec![layer]);
        assert!(!compositor.has_layer(layer));

        // LED 80 reverts to base color
        assert_eq!(compositor.compose()[80], base_color);
    }

    /// Test scenario: 수명이 남은 레이어는 tick에서 살아남는다.
    #[test]
    fn test_unexpired_layer_survives_ticks() {
        let mut compositor = Compositor::new();

        let l1 = compositor.register_layer(
            None,
            "short",
            CompositeZIndex(1),
            Some(Duration::from_millis(50)),
        );
        let l2 = compositor.register_layer(
            None,
            "long",
            CompositeZIndex(2),
            Some(Duration::from_millis(200)),
        );
        let l_permanent = compositor.register_layer(None, "perm", CompositeZIndex(3), None);

        // Tick 60ms: l1 expires, l2 and l_permanent survive
        let expired = compositor.tick_elapsed(Duration::from_millis(60));
        assert_eq!(expired, vec![l1]);
        assert!(!compositor.has_layer(l1));
        assert!(compositor.has_layer(l2));
        assert!(compositor.has_layer(l_permanent));

        // Remaining lifetime of l2 is now 140ms
        let l2_layer = compositor.get_layer(l2).unwrap();
        assert_eq!(
            l2_layer.remaining_lifetime,
            Some(Duration::from_millis(140))
        );
    }

    /// Test scenario: 다층 스택 합성에서 중간 레이어를 제거하거나 픽셀을 거두면 아래 레이어가 정확히 드러난다.
    #[test]
    fn test_multi_layer_stack_composition_and_retraction() {
        let base_color = Color::rgb(10, 10, 10);
        let mut compositor = Compositor::with_base_color(base_color);

        let red = Color::rgb(255, 0, 0);
        let green = Color::rgb(0, 255, 0);
        let blue = Color::rgb(0, 0, 255);

        // Layer 1 at z = 10 paints LED 20 Red
        let l1 = compositor.register_layer(None, "bottom", CompositeZIndex(10), None);
        compositor.set_pixel(l1, 20, red).unwrap();

        // Layer 2 at z = 20 paints LED 20 Green
        let l2 = compositor.register_layer(None, "middle", CompositeZIndex(20), None);
        compositor.set_pixel(l2, 20, green).unwrap();

        // Layer 3 at z = 30 paints LED 20 Blue
        let l3 = compositor.register_layer(None, "top", CompositeZIndex(30), None);
        compositor.set_pixel(l3, 20, blue).unwrap();

        // Topmost (Layer 3) wins: Blue
        assert_eq!(compositor.compose()[20], blue);

        // Top layer retracts LED 20 -> Middle (Layer 2) shows through: Green
        compositor.retract_pixel(l3, 20).unwrap();
        assert_eq!(compositor.compose()[20], green);

        // Middle layer removed -> Bottom (Layer 1) shows through: Red
        compositor.remove_layer(l2).unwrap();
        assert_eq!(compositor.compose()[20], red);

        // Bottom layer removed -> Base layer shows through
        compositor.remove_layer(l1).unwrap();
        assert_eq!(compositor.compose()[20], base_color);
    }

    /// Test scenario: update_layer로 픽셀 설정과 거두기를 한 번에 수행한다.
    #[test]
    fn test_update_layer_batch_set_and_retract() {
        let mut compositor = Compositor::with_base_color(Color::BLACK);
        let layer = compositor.register_layer(None, "batch", CompositeZIndex(1), None);

        compositor.set_pixel(layer, 1, Color::WHITE).unwrap();
        compositor.set_pixel(layer, 2, Color::WHITE).unwrap();

        // In one update: set LED 3 to red, retract LED 1
        let red = Color::rgb(255, 0, 0);
        compositor
            .update_layer(layer, vec![(3, red)], vec![1])
            .unwrap();

        let frame = compositor.compose();
        assert_eq!(frame[1], Color::BLACK); // Retracted -> shows base (black)
        assert_eq!(frame[2], Color::WHITE); // Kept
        assert_eq!(frame[3], red); // Newly set
    }

    /// Test scenario: tick_at으로 Instant 기반 수명 만료가 작동한다.
    #[test]
    fn test_tick_at_advances_time() {
        let mut compositor = Compositor::new();
        let layer = compositor.register_layer(
            None,
            "timer",
            CompositeZIndex(1),
            Some(Duration::from_millis(100)),
        );

        let t0 = Instant::now();
        // First tick sets reference time
        let expired = compositor.tick_at(t0);
        assert!(expired.is_empty());

        // Tick 50ms later
        let expired = compositor.tick_at(t0 + Duration::from_millis(50));
        assert!(expired.is_empty());
        assert!(compositor.has_layer(layer));

        // Tick 110ms later
        let expired = compositor.tick_at(t0 + Duration::from_millis(110));
        assert_eq!(expired, vec![layer]);
        assert!(!compositor.has_layer(layer));
    }

    /// Test scenario: LedDiff와 wire::LedColor 간 변환 검증
    #[test]
    fn test_led_diff_wire_color_conversion() {
        let diff = LedDiff {
            led_index: 15,
            color: Color::rgb(10, 20, 30),
        };
        let proto_color: crate::wire::LedColor = diff.into();
        assert_eq!(proto_color.led_index, 15);
        assert_eq!(proto_color.red, 10);
        assert_eq!(proto_color.green, 20);
        assert_eq!(proto_color.blue, 30);

        let (idx, c): (usize, Color) = proto_color.into();
        assert_eq!(idx, 15);
        assert_eq!(c, Color::rgb(10, 20, 30));
    }

    #[test]
    fn test_invalid_led_index_rejected() {
        let mut compositor = Compositor::new();
        let layer = compositor.register_layer(None, "test", CompositeZIndex(1), None);

        assert_eq!(
            compositor.set_pixel(layer, 101, Color::WHITE),
            Err(CompositorError::InvalidLedIndex(101))
        );
        assert_eq!(
            compositor.retract_pixel(layer, 999),
            Err(CompositorError::InvalidLedIndex(999))
        );
    }

    #[test]
    fn test_base_layer_immutable_against_removal() {
        let mut compositor = Compositor::new();
        assert_eq!(
            compositor.remove_layer(BASE_LAYER_ID),
            Err(CompositorError::BaseLayerImmutable)
        );
    }

    #[test]
    fn test_layer_summaries() {
        let mut compositor = Compositor::new();
        let l1 = compositor.register_layer(
            None,
            "first",
            CompositeZIndex(10),
            Some(Duration::from_millis(500)),
        );
        compositor.set_pixel(l1, 1, Color::WHITE).unwrap();
        compositor.set_pixel(l1, 2, Color::WHITE).unwrap();

        let summaries = compositor.layer_summaries();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].layer_id, l1.0);
        assert_eq!(summaries[0].name, "first");
        assert_eq!(summaries[0].z_order, 10);
        assert_eq!(summaries[0].pixel_count, 2);
        assert_eq!(summaries[0].remaining_lifetime_ms, Some(500));
    }

    #[test]
    fn test_compose_bytes_format() {
        let base_color = Color::rgb(1, 2, 3);
        let compositor = Compositor::with_base_color(base_color);
        let bytes = compositor.compose_bytes();

        assert_eq!(bytes.len(), GEM80_PIXEL_BUFFER_BYTES);
        for chunk in bytes.chunks_exact(3) {
            assert_eq!(chunk, &[1, 2, 3]);
        }
    }
}
