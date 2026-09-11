# gem80-rgb

Host lighting daemon, client library, and operator CLI for the NuPhy Gem80 keyboard running custom HostRGB (`0x60`) firmware.

## Deployment Status

Nothing in this repository currently installs or runs `gem80-rgbd` automatically.
This repository does not yet deploy Rust binaries.
Daemon packaging and service deployment (such as a systemd user service) are separate future tasks.
To run the daemon now, build and start it manually:

```sh
cd crates/gem80-rgb
cargo run --features daemon --bin gem80-rgbd
```

This crate is standalone — there is no Cargo workspace at the repository
root, so every `cargo` command runs from the crate directory.

## Components

The crate provides one library and two binaries:

- **`gem80_rgb` (library)**: High-level client library for applications (such as fcitx5 input method indicators or desktop notifications) to control keyboard lighting. Applications register layers and set pixel colors without raw HID access or protobuf framing knowledge.
- **`gem80-rgbd` (daemon binary)**: The host RGB background service. It holds exclusive host ownership of the keyboard raw HID device, runs the render loop, composes active client layers over a configurable base layer, and listens for client connections on an AF_UNIX domain socket. It requires the `daemon` feature.
- **`gem80-rgbctl` (CLI binary)**: A command-line tool for human operators. It inspects daemon status, lists layers, dumps composite frames, and creates temporary foreground layers. It communicates strictly through the AF_UNIX socket and does not access the HID device.

## Feature Flags and Dependencies

The crate isolates native HID dependencies:

- **`default` (`[]`)**: Builds the client library and `gem80-rgbctl`. It does not link `hidapi` or C libraries such as `libudev`. Clients depending on `gem80-rgb` build as pure Rust crates.
- **`daemon` (`["dep:hidapi"]`)**: Enables `gem80-rgbd` along with the internal `device`, `device_state`, and `render` modules. It links `hidapi` (`linux-static-hidraw` on Linux, `macos-shared-device` on macOS).

## Runtime Paths

`src/paths.rs` resolves runtime sockets, lockfiles, and configuration files:

- **Runtime Directory**: Reads `$XDG_RUNTIME_DIR`. If empty or unset, it falls back to `$TMPDIR`. If `$TMPDIR` is empty or unset, it falls back to `/tmp`.
- **Socket Path**: `<runtime_dir>/gem80-rgb.sock` (`DEFAULT_SOCKET_NAME = "gem80-rgb.sock"`).
- **Lockfile Path**: `<runtime_dir>/gem80-rgb.lock` (`DEFAULT_LOCK_NAME = "gem80-rgb.lock"`). The daemon acquires this advisory lock before opening the socket or accessing the HID node, enforcing single-instance execution.
- **Configuration Directory**: `$XDG_CONFIG_HOME/gem80-rgb` if `$XDG_CONFIG_HOME` is set. Otherwise, `~/.config/gem80-rgb` if `$HOME` is set.
- **Configuration Path**: `<config_dir>/config.toml` (`CONFIG_FILE_NAME = "config.toml"`).

## Configuration

`src/config.rs` parses the TOML configuration.
The configuration defines the static base layer that displays when no client layers override it.
If the file does not exist, the daemon falls back to a uniform soft warm white (`#b4b4b4` / `[180, 180, 180]`).

### Minimal `config.toml` Example

```toml
[base]
# Uniform fallback color for all 101 LEDs (#RRGGBB, #RGB, or [R, G, B])
color = "#201810"

# Optional override for the 89 key LEDs (indices 0..89)
keys_color = "#302010"

# Optional override for the 12 side strip and logo LEDs (indices 89..101)
side_color = "#101020"

# Optional per-LED overrides by index
leds = { "0" = "#ffffff" }
```

LED indices span `0..101` total:
- Indices `0..89`: Keys region (89 LEDs).
- Indices `89..101`: Side strip and logo region (12 LEDs).

## Client API Example

Client applications depend on `gem80-rgb` with default features.
`LayerHandle` uses RAII to manage layer lifetime.
When the handle drops, the client library automatically requests layer release, and underlying layers or base colors show through.

```rust
use std::thread;
use std::time::Duration;
use gem80_rgb::client::Client;
use gem80_rgb::compositor::Color;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Connect to the daemon over the default AF_UNIX socket.
    let client = Client::connect()?;

    // Register a layer with name and z-order.
    // Higher z-order values composite above lower layers.
    let layer = client.register_layer("status-indicator", 100)?;

    // Set individual pixels (Esc key at index 0, CapsLock at index 30).
    layer.set_pixel(0, Color::new(255, 0, 0))?;
    layer.set_pixel(30, Color::new(0, 255, 0))?;

    // The layer stays active while the handle is in scope.
    thread::sleep(Duration::from_secs(5));

    // Dropping `layer` sends an unregister request over the socket.
    // Underlying layers and the base layer immediately show through.
    drop(layer);

    Ok(())
}
```

If a client process crashes or disconnects without dropping `layer`, the daemon detects socket closure and removes all layers registered on that connection.

## Operator CLI Usage

Use `gem80-rgbctl` to inspect daemon state and test layers:

```sh
# Show daemon connection status and active layers
gem80-rgbctl status

# List active layers
gem80-rgbctl layers

# Dump the current 101-LED composite frame
gem80-rgbctl frame

# Hold a temporary static layer in the foreground (releases on Ctrl+C)
gem80-rgbctl layer --name test --color "#0000ff" --leds 0..10
```
