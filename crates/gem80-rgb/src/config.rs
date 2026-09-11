//! TOML configuration parser for base layer settings.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub use crate::compositor::Color;

/// Errors encountered while reading or parsing daemon configuration.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// Failed to read config file from disk.
    #[error("failed to read config file at {0}: {1}")]
    Io(PathBuf, #[source] std::io::Error),

    /// Failed to parse TOML configuration syntax or structure.
    #[error("failed to parse TOML configuration at {0}: {1}")]
    Toml(PathBuf, #[source] toml::de::Error),

    /// Invalid color format or value.
    #[error("invalid color specification: {0}")]
    InvalidColor(String),
}

/// Helper for deserializing flexible color representations in TOML.
#[derive(serde::Deserialize)]
#[serde(untagged)]
enum ColorDef {
    Color(Color),
    Array([u8; 3]),
    Hex(String),
}

fn parse_hex_color(s: &str) -> Result<Color, String> {
    let hex = s.trim().trim_start_matches('#');
    match hex.len() {
        6 => {
            let r = u8::from_str_radix(&hex[0..2], 16)
                .map_err(|e| format!("invalid red hex in '{s}': {e}"))?;
            let g = u8::from_str_radix(&hex[2..4], 16)
                .map_err(|e| format!("invalid green hex in '{s}': {e}"))?;
            let b = u8::from_str_radix(&hex[4..6], 16)
                .map_err(|e| format!("invalid blue hex in '{s}': {e}"))?;
            Ok(Color::new(r, g, b))
        }
        3 => {
            let r = u8::from_str_radix(&hex[0..1], 16)
                .map_err(|e| format!("invalid red hex in '{s}': {e}"))?;
            let g = u8::from_str_radix(&hex[1..2], 16)
                .map_err(|e| format!("invalid green hex in '{s}': {e}"))?;
            let b = u8::from_str_radix(&hex[2..3], 16)
                .map_err(|e| format!("invalid blue hex in '{s}': {e}"))?;
            Ok(Color::new(r * 17, g * 17, b * 17))
        }
        other => Err(format!(
            "invalid hex color '{s}': expected 3 or 6 hex digits, got {other}"
        )),
    }
}

impl TryFrom<ColorDef> for Color {
    type Error = String;

    fn try_from(def: ColorDef) -> Result<Self, Self::Error> {
        match def {
            ColorDef::Color(c) => Ok(c),
            ColorDef::Array([r, g, b]) => Ok(Color::new(r, g, b)),
            ColorDef::Hex(s) => parse_hex_color(&s),
        }
    }
}

fn deserialize_color<'de, D>(deserializer: D) -> Result<Color, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let def = ColorDef::deserialize(deserializer)?;
    Color::try_from(def).map_err(serde::de::Error::custom)
}

fn deserialize_opt_color<'de, D>(deserializer: D) -> Result<Option<Color>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let opt: Option<ColorDef> = Option::deserialize(deserializer)?;
    match opt {
        Some(def) => Color::try_from(def)
            .map(Some)
            .map_err(serde::de::Error::custom),
        None => Ok(None),
    }
}

fn deserialize_led_map<'de, D>(deserializer: D) -> Result<HashMap<u32, Color>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw_map = HashMap::<String, ColorDef>::deserialize(deserializer)?;
    let mut out = HashMap::with_capacity(raw_map.len());
    for (k, v) in raw_map {
        let index: u32 = k
            .parse()
            .map_err(|e| serde::de::Error::custom(format!("invalid LED index '{k}': {e}")))?;
        if index as usize >= crate::wire::GEM80_TOTAL_LEDS {
            return Err(serde::de::Error::custom(format!(
                "LED index {index} out of bounds (must be < {})",
                crate::wire::GEM80_TOTAL_LEDS
            )));
        }
        let color = Color::try_from(v).map_err(serde::de::Error::custom)?;
        out.insert(index, color);
    }
    Ok(out)
}

/// Returns the built-in fallback default base color (soft warm white, R8).
pub fn default_base_color() -> Color {
    crate::compositor::DEFAULT_BASE_COLOR
}

/// Configuration for the static base lighting layer (R8).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct BaseLayerConfig {
    /// Base color applied uniformly to all LEDs unless overridden (R8).
    #[serde(default = "default_base_color", deserialize_with = "deserialize_color")]
    pub color: Color,

    /// Optional specific color for the keys region (indices 0..89).
    #[serde(default, deserialize_with = "deserialize_opt_color")]
    pub keys_color: Option<Color>,

    /// Optional specific color for the side strip and logo (indices 89..101).
    #[serde(default, deserialize_with = "deserialize_opt_color")]
    pub side_color: Option<Color>,

    /// Optional per-LED overrides (e.g. index -> Color).
    #[serde(default, deserialize_with = "deserialize_led_map")]
    pub leds: HashMap<u32, Color>,
}

impl Default for BaseLayerConfig {
    fn default() -> Self {
        Self {
            color: default_base_color(),
            keys_color: None,
            side_color: None,
            leds: HashMap::new(),
        }
    }
}

impl BaseLayerConfig {
    /// Creates a base layer config with a uniform color across all LEDs.
    pub fn new(color: Color) -> Self {
        Self {
            color,
            keys_color: None,
            side_color: None,
            leds: HashMap::new(),
        }
    }

    /// Evaluates the base color for a given LED index according to specificity:
    /// 1. Specific LED override in `leds`
    /// 2. Region-specific override (`keys_color` for 0..89, `side_color` for 89..101)
    /// 3. Default base `color`
    pub fn led_color(&self, index: usize) -> Color {
        if let Some(&c) = self.leds.get(&(index as u32)) {
            return c;
        }
        if index < 89 {
            if let Some(c) = self.keys_color {
                return c;
            }
        } else if index < crate::wire::GEM80_TOTAL_LEDS {
            if let Some(c) = self.side_color {
                return c;
            }
        }
        self.color
    }

    /// Converts base layer configuration into a 101-element array of LED colors.
    pub fn to_led_colors(&self) -> [Color; crate::wire::GEM80_TOTAL_LEDS] {
        let mut out = [self.color; crate::wire::GEM80_TOTAL_LEDS];
        for i in 0..crate::wire::GEM80_TOTAL_LEDS {
            out[i] = self.led_color(i);
        }
        out
    }

    /// Applies this base layer configuration to the compositor (R8).
    pub fn apply_to_compositor(&self, compositor: &mut crate::compositor::Compositor) {
        let colors = self.to_led_colors();
        let _ = compositor.set_base_pixels(colors.into_iter().enumerate());
    }
}

/// Top-level daemon configuration.
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct Config {
    #[serde(default)]
    pub base: BaseLayerConfig,
}

impl Config {
    /// Parses a configuration from a TOML string.
    pub fn from_toml(content: &str) -> Result<Self, toml::de::Error> {
        toml::from_str(content)
    }

    /// Loads configuration from a file path.
    pub fn load_from_path(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let content =
            std::fs::read_to_string(path).map_err(|e| ConfigError::Io(path.to_path_buf(), e))?;
        toml::from_str(&content).map_err(|e| ConfigError::Toml(path.to_path_buf(), e))
    }

    /// Loads configuration from a path, falling back to the built-in default base layer
    /// if the file does not exist or if reading/parsing fails (R8).
    ///
    /// Returns `(config, Option<ConfigError>)`. If an error occurred, the error is returned
    /// alongside the default configuration so the caller can observe what went wrong.
    pub fn load_from_path_or_default(path: impl AsRef<Path>) -> (Self, Option<ConfigError>) {
        let path = path.as_ref();
        if !path.exists() {
            log::info!(
                "Config file not found at {}; using built-in default base layer",
                path.display()
            );
            return (Self::default(), None);
        }

        match Self::load_from_path(path) {
            Ok(cfg) => {
                log::info!("Loaded base layer configuration from {}", path.display());
                (cfg, None)
            }
            Err(err) => {
                log::warn!(
                    "Failed to load configuration from {}: {err}; falling back to built-in default base layer",
                    path.display()
                );
                (Self::default(), Some(err))
            }
        }
    }

    /// Loads configuration from the default system path ($XDG_CONFIG_HOME/gem80-rgb/config.toml
    /// or ~/.config/gem80-rgb/config.toml), or falls back to built-in default base layer (R8).
    pub fn load_default() -> (Self, Option<ConfigError>) {
        if let Some(path) = crate::paths::default_config_path() {
            Self::load_from_path_or_default(path)
        } else {
            log::info!("No default config path found; using built-in default base layer");
            (Self::default(), None)
        }
    }
}

#[cfg(test)]
mod tests {
    /// Tests write under the crate's own build directory rather than the ambient
    /// temp root. A shared `/tmp` is not reliably writable from a sandboxed test
    /// process, and a leftover directory from another run would collide.
    fn test_dir(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join("test-tmp")
            .join(format!("{}-{}", name, std::process::id()))
    }

    use super::*;

    #[test]
    fn test_missing_config_yields_non_off_default() {
        let temp_dir = test_dir("gem80-cfg-test-missing");
        let missing_path = temp_dir.join("nonexistent_config.toml");

        let (config, err) = Config::load_from_path_or_default(&missing_path);
        assert!(err.is_none(), "missing config should not produce an error");
        assert_ne!(
            config.base.color,
            Color::BLACK,
            "R8: default base color must not be off"
        );
        assert_eq!(config.base.color, crate::compositor::DEFAULT_BASE_COLOR);

        let colors = config.base.to_led_colors();
        assert_eq!(colors.len(), crate::wire::GEM80_TOTAL_LEDS);
        assert!(!colors.iter().any(|&c| c == Color::BLACK));
    }

    #[test]
    fn test_corrupt_toml_falls_back_to_default_with_observable_error() {
        let temp_dir = test_dir("gem80-cfg-test-corrupt");
        std::fs::create_dir_all(&temp_dir).unwrap();
        let bad_path = temp_dir.join("bad_config.toml");

        // Write corrupt TOML
        std::fs::write(&bad_path, b"[base\ncolor = \"broken").unwrap();

        let (config, err) = Config::load_from_path_or_default(&bad_path);
        assert!(err.is_some(), "corrupt TOML must yield an observable error");
        let err = err.unwrap();
        match err {
            ConfigError::Toml(p, _) => assert_eq!(p, bad_path),
            other => panic!("expected ConfigError::Toml, got {:?}", other),
        }

        // Even with corrupt TOML, daemon receives default base color and can continue (R8)
        assert_ne!(config.base.color, Color::BLACK);
        assert_eq!(config.base.color, crate::compositor::DEFAULT_BASE_COLOR);

        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_parse_valid_toml_various_color_formats() {
        let toml_str = r##"
[base]
color = "#112233"
keys_color = [100, 150, 200]
side_color = { r = 10, g = 20, b = 30 }

[base.leds]
0 = "#ffffff"
1 = "#fff"
89 = [255, 0, 0]
"##;

        let config = Config::from_toml(toml_str).expect("parse valid toml");
        assert_eq!(config.base.color, Color::new(0x11, 0x22, 0x33));
        assert_eq!(config.base.keys_color, Some(Color::new(100, 150, 200)));
        assert_eq!(config.base.side_color, Some(Color::new(10, 20, 30)));

        // Specific overrides
        assert_eq!(config.base.led_color(0), Color::new(255, 255, 255));
        assert_eq!(config.base.led_color(1), Color::new(255, 255, 255));
        assert_eq!(config.base.led_color(89), Color::new(255, 0, 0));

        // Regional fallbacks
        assert_eq!(config.base.led_color(10), Color::new(100, 150, 200)); // keys
        assert_eq!(config.base.led_color(90), Color::new(10, 20, 30)); // side

        let colors = config.base.to_led_colors();
        assert_eq!(colors[0], Color::new(255, 255, 255));
        assert_eq!(colors[1], Color::new(255, 255, 255));
        assert_eq!(colors[10], Color::new(100, 150, 200));
        assert_eq!(colors[89], Color::new(255, 0, 0));
        assert_eq!(colors[90], Color::new(10, 20, 30));
    }

    #[test]
    fn test_apply_to_compositor() {
        let toml_str = r#"
[base]
color = [50, 60, 70]
keys_color = [80, 90, 100]
side_color = [110, 120, 130]

[base.leds]
5 = [200, 201, 202]
"#;
        let config = Config::from_toml(toml_str).expect("parse valid toml");
        let mut compositor = crate::compositor::Compositor::new();

        config.base.apply_to_compositor(&mut compositor);

        let base_layer = compositor.base_layer();
        assert_eq!(base_layer.pixels.get(&5), Some(&Color::new(200, 201, 202)));
        assert_eq!(base_layer.pixels.get(&0), Some(&Color::new(80, 90, 100)));
        assert_eq!(base_layer.pixels.get(&90), Some(&Color::new(110, 120, 130)));
    }

    #[test]
    fn test_out_of_bounds_led_index_rejected() {
        let toml_str = r##"
[base.leds]
101 = "#ffffff"
"##;
        let err = Config::from_toml(toml_str).expect_err("index 101 must be rejected");
        assert!(err.to_string().contains("out of bounds"));
    }
}
