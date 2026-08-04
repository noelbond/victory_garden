# Desktop Installer Testing

## Automated

From [desktop_installer](/Users/noel/coding/python/victory_garden/desktop_installer):

```bash
npm test
npm run build
```

From [src-tauri](/Users/noel/coding/python/victory_garden/desktop_installer/src-tauri):

```bash
cargo test
cargo check
```

## Covered By Automated Tests

- URL normalization
- Pi discovery error classification
- Retry/backoff behavior for transient Pi API failures
- Provisioning payload generation
- Installer step progression / resume step selection
- BOOTSEL board inference helpers
- macOS serial endpoint normalization
- Provisioning retry classification helpers
- Pi URL parsing in the Rust backend

## Manual Hardware Testing Required

These paths still require real hardware validation because they depend on USB mass-storage timing, USB serial timing, Wi‑Fi join behavior, and the live Pi backend.

### 1. Setup API Communication Against A Real Pi

Validate:

- Find Pi during first boot
- Find Pi while the Pi web app is still starting
- Resume after closing the installer mid-setup
- Resume after Pi reboot
- Reading, calibration, and watering retries against a live Pi

### 2. Device Detection Workflows

Validate:

- No Pico attached
- One Pico W in BOOTSEL
- One Pico 2 W / RP2350 in BOOTSEL
- Two BOOTSEL devices attached at once
- BOOTSEL device appears slowly after user action
- BOOTSEL device disappears during flash

### 3. Provisioning Workflows

Validate:

- Serial port appears normally after flash
- Serial port appears, disconnects, then reappears
- Duplicate `/dev/cu.*` and `/dev/tty.*` macOS endpoints
- Provisioning ACK success
- Provisioning ACK timeout
- Invalid provisioning ACK payload
- Sensor Pico online/assigned after provisioning
- Actuator Pico online after provisioning

### 4. Runtime Diagnostics

Validate:

- Sensor hardware missing
- Sensor initialization failure
- Wi‑Fi join failure
- MQTT authentication failure
- MQTT broker unavailable
- Reading timeout
- Calibration timeout / stale readings
- Watering timeout

## Recommended Manual Matrix

Run at least:

1. Pico W sensor + Pico W actuator
2. Pico W sensor + Pico 2 W actuator
3. Pico 2 W sensor + Pico 2 W actuator
4. Fresh install from Raspberry Pi Imager
5. Resume after installer restart
6. Resume after Pi reboot during setup
