# Victory Garden Desktop Installer

This is the macOS-first desktop companion for the Victory Garden install path.

It is the user-facing setup app that:

- finds the Pi after it boots from the Victory Garden image
- saves the first Victory Garden settings
- creates the first crop profile and zone
- flashes Pico W and Pico 2 W firmware
- provisions both Pico boards over USB serial
- validates the first reading, calibration, and watering cycle

## Current scope

The installer assumes the user already:

- flashed the Victory Garden Pi image with Raspberry Pi Imager
- booted the Pi
- connected the Pi to the network

After that, the installer owns the full first-run flow.

## Tech stack

- Tauri 2
- Vite
- plain HTML/CSS/JS frontend
- Rust backend commands for BOOTSEL detection and UF2 flashing

## Development

From [`desktop_installer/`](../desktop_installer):

```bash
npm install
npm run tauri:dev
```

## Packaging

To build a real macOS app bundle and release artifacts:

```bash
./deploy/build_desktop_installer.sh
```

That exports:

- `deploy/releases/Victory Garden Installer.app`
- `deploy/releases/victory-garden-installer-macos-<version>.zip`

## MVP constraints

- macOS-first BOOTSEL detection is implemented explicitly through `/Volumes`
- Linux removable-media paths are also checked
- Windows support is not implemented yet
- the installer expects the Pi image to be created separately in Raspberry Pi Imager
- the bundled macOS app is currently unsigned / not notarized
- the shipped macOS download is a zipped `.app`, not a DMG
