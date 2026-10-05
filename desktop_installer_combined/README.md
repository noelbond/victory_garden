# Victory Garden Combined-Node Desktop Installer

This directory contains the development/demo provisioning companion for the combined sensor-and-actuator Pico firmware. It supports bench testing and end-to-end demonstrations where one Pico performs both roles.

The combined-node topology is not the production architecture. Production installations use separate sensor packages and one dedicated greenhouse-wide actuator controller; use [`desktop_installer/`](../desktop_installer) for that workflow.

## Tech stack

- Tauri 2
- Vite
- plain HTML/CSS/JS frontend
- Rust backend commands for BOOTSEL detection and UF2 flashing

## Development

From this directory:

```bash
npm install
npm run tauri:dev
```

## Local build

```bash
npm run tauri:build
```

The repository's production desktop-installer release script does not package this combined-node development tool.
