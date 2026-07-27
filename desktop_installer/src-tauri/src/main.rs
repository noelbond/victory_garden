use serde::{Deserialize, Deserializer, Serialize};
use serde::de::DeserializeOwned;
use serde_json::json;
use serialport::{available_ports, ClearBuffer, SerialPortType};
use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::AppHandle;
use tauri::Manager;

const DEFAULT_WIZARD_URL: &str = "http://victory-garden.local:3000";
const INSTALLER_LOG_DIR: &str = "logs";
const INSTALLER_LOG_FILE: &str = "installer.log";
const INSTALLER_LOG_ROTATED_FILE: &str = "installer.log.1";
const INSTALLER_LOG_MAX_BYTES: u64 = 1_000_000;
const INSTALLER_SUPPORT_DIR: &str = "support-bundles";
const TAURI_RUNTIME_VERSION: &str = "2.11.2";
// Must match firmware VG_ADS1115_CHANNEL_COUNT.
const EXPECTED_SENSOR_CHANNEL_COUNT: usize = 4;

#[derive(Clone, Serialize)]
struct BootselDevice {
    board: String,
    volume_name: String,
    mount_path: String,
}

#[derive(Serialize)]
struct FlashResult {
    board: String,
    kind: String,
    operation_id: String,
    flashed_filename: String,
    flashed_path: String,
    device: BootselDevice,
}

#[derive(Serialize)]
struct ProbeResult {
    url: String,
    status_code: u16,
}

#[derive(Clone, Serialize, Deserialize)]
struct InstallerLogEntryInput {
    level: String,
    category: String,
    action: String,
    message: String,
    details: Option<serde_json::Value>,
}

#[derive(Serialize)]
struct SupportBundleExportResult {
    zip_path: String,
    bundle_dir: String,
}

#[derive(Deserialize)]
struct ExportSupportBundleInput {
    #[serde(rename = "setupState")]
    setup_state: serde_json::Value,
}

#[derive(Serialize, Deserialize)]
struct SetupStatus {
    connection_ready: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    first_zone_ready: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    watering_targets_ready: Option<bool>,
    zone_ready: bool,
    detected_node_ready: bool,
    assigned_node_ready: bool,
    reading_ready: bool,
    calibration_ready: bool,
    watering_ready: bool,
}

#[derive(Serialize, Deserialize)]
struct SetupConnectionSetting {
    mqtt_host: Option<String>,
    mqtt_port: Option<u16>,
    mqtt_username: Option<String>,
    provisioning_mqtt_username: Option<String>,
    provisioning_mqtt_password: Option<String>,
    irrigation_line_count: Option<u16>,
    readings_topic: Option<String>,
    actuators_topic: Option<String>,
    command_topic: Option<String>,
    config_topic: Option<String>,
    bluetooth_enabled: Option<bool>,
    notes: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
struct SetupCropProfile {
    id: u64,
    crop_id: String,
    crop_name: String,
    #[serde(deserialize_with = "deserialize_f64ish")]
    dry_threshold: f64,
    max_pulse_runtime_sec: u16,
    daily_max_runtime_sec: u16,
    climate_preference: Option<String>,
    time_to_harvest_days: Option<u16>,
    notes: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct SetupZone {
    id: u64,
    zone_id: String,
    name: Option<String>,
    crop_profile_id: Option<u64>,
    crop_profile_name: Option<String>,
    irrigation_line: Option<u16>,
    publish_interval_ms: Option<u32>,
    active: bool,
}

#[derive(Serialize, Deserialize)]
struct SetupNode {
    id: u64,
    node_id: String,
    name: Option<String>,
    device_id: Option<String>,
    #[serde(default)]
    channels: Vec<SetupNode>,
    zone_id: Option<u64>,
    zone_name: Option<String>,
    assigned: bool,
    reported_zone_id: Option<String>,
    provisioned: Option<bool>,
    config_status: Option<String>,
    last_seen_at: Option<String>,
    moisture_raw_dry: Option<u64>,
    moisture_raw_wet: Option<u64>,
    calibration_configured: Option<bool>,
    crop_profile_id: Option<u64>,
    crop_profile_name: Option<String>,
    effective_crop_profile_id: Option<u64>,
    effective_crop_profile_name: Option<String>,
    irrigation_line: Option<u16>,
    watering_configured: Option<bool>,
}

#[derive(Serialize, Deserialize)]
struct SetupBootstrapResponse {
    status: SetupStatus,
    setup_watering: Option<SetupWateringAttempt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    setup_actuator: Option<serde_json::Value>,
    connection_setting: SetupConnectionSetting,
    crop_profiles: Vec<SetupCropProfile>,
    first_zone: Option<SetupZone>,
    detected_node: Option<SetupNode>,
    assigned_node: Option<SetupNode>,
}

#[derive(Serialize, Deserialize)]
struct SetupConnectionResponse {
    status: SetupStatus,
    connection_setting: SetupConnectionSetting,
}

#[derive(Serialize, Deserialize)]
struct SetupCropProfileResponse {
    status: SetupStatus,
    crop_profile: SetupCropProfile,
    crop_profiles: Vec<SetupCropProfile>,
}

#[derive(Serialize, Deserialize)]
struct SetupZoneResponse {
    status: SetupStatus,
    first_zone: SetupZone,
}

#[derive(Serialize, Deserialize)]
struct SetupNodeStatusResponse {
    detected: bool,
    assigned: bool,
    node: Option<SetupNode>,
    first_zone: Option<SetupZone>,
}

#[derive(Serialize, Deserialize)]
struct SetupAssignNodeResponse {
    assigned: bool,
    node: SetupNode,
    first_zone: SetupZone,
    status: SetupStatus,
}

#[derive(Serialize, Deserialize)]
struct SetupUpdateNodeResponse {
    node: SetupNode,
    status: SetupStatus,
}

#[derive(Serialize, Deserialize)]
struct SetupSensorReading {
    id: u64,
    node_id: String,
    recorded_at: Option<String>,
    moisture_raw: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_option_f64ish")]
    moisture_percent: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_option_f64ish")]
    air_temperature_c: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_option_f64ish")]
    humidity_percent: Option<f64>,
    greenhouse_alert_status: Option<String>,
    health: Option<String>,
    last_error: Option<String>,
    publish_reason: Option<String>,
    #[serde(default, deserialize_with = "deserialize_option_f64ish")]
    battery_percent: Option<f64>,
    wifi_rssi: Option<i64>,
}

#[derive(Serialize, Deserialize)]
struct SetupRequestReadingResponse {
    queued: bool,
    command_id: String,
    requested_at: String,
    node: SetupNode,
}

#[derive(Serialize, Deserialize)]
struct SetupReadingStatusResponse {
    complete: bool,
    node: Option<SetupNode>,
    reading: Option<SetupSensorReading>,
}

#[derive(Serialize, Deserialize)]
struct SetupCalibrationResponse {
    node: SetupNode,
    status: SetupStatus,
}

#[derive(Serialize, Deserialize)]
struct SetupActuatorStatus {
    id: u64,
    zone_id: String,
    node_id: Option<String>,
    state: String,
    recorded_at: Option<String>,
    actual_runtime_seconds: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_option_f64ish")]
    flow_ml: Option<f64>,
}

#[derive(Serialize, Deserialize)]
struct SetupWateringEvent {
    id: u64,
    zone_id: String,
    node_id: Option<String>,
    command: String,
    status: String,
    reason: Option<String>,
    runtime_seconds: Option<u64>,
    issued_at: Option<String>,
    idempotency_key: String,
}

#[derive(Serialize, Deserialize)]
struct SetupWateringTarget {
    kind: Option<String>,
    zone_id: Option<String>,
    node_id: Option<String>,
    irrigation_line: Option<u16>,
    crop_profile_id: Option<u64>,
    runtime_seconds: Option<u64>,
}

#[derive(Serialize, Deserialize)]
struct SetupWateringAttempt {
    state: String,
    complete: bool,
    terminal: bool,
    outcome: String,
    message: Option<String>,
    idempotency_key: Option<String>,
    target_matches_current: Option<bool>,
    invalidated_at: Option<String>,
    invalidation_reason: Option<String>,
    superseded_at: Option<String>,
    supersession_reason: Option<String>,
    event: Option<SetupWateringEvent>,
    target: Option<SetupWateringTarget>,
}

#[derive(Serialize, Deserialize)]
struct SetupStartWateringResponse {
    queued: bool,
    idempotency_key: String,
    issued_at: String,
    setup_watering: Option<SetupWateringAttempt>,
    zone: SetupZone,
    node: Option<SetupNode>,
}

#[derive(Serialize, Deserialize)]
struct SetupWateringStatusResponse {
    complete: bool,
    terminal: Option<bool>,
    outcome: Option<String>,
    message: Option<String>,
    event: Option<SetupWateringEvent>,
    actuator_status: Option<SetupActuatorStatus>,
    setup_watering: Option<SetupWateringAttempt>,
    zone: Option<SetupZone>,
    node: Option<SetupNode>,
}

#[derive(Serialize, Deserialize)]
struct SetupActuatorProvisioningResponse {
    recorded: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    setup_actuator: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    status: Option<SetupStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Deserialize)]
struct ErrorResponse {
    errors: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SaveConnectionInput {
    base_url: String,
    mqtt_host: String,
    mqtt_port: u16,
    mqtt_username: String,
    mqtt_password: String,
    irrigation_line_count: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateCropProfileInput {
    base_url: String,
    crop_name: String,
    dry_threshold: f64,
    max_pulse_runtime_sec: u16,
    daily_max_runtime_sec: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SaveZoneInput {
    base_url: String,
    name: String,
    publish_interval_hours: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetupNodeStatusInput {
    base_url: String,
    node_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AssignSetupNodeInput {
    base_url: String,
    node_id: String,
    zone_id: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateSetupNodeInput {
    base_url: String,
    node_id: String,
    name: String,
    crop_profile_id: u64,
    irrigation_line: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RequestSetupReadingInput {
    base_url: String,
    node_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetupReadingStatusInput {
    base_url: String,
    node_id: String,
    since: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SaveSetupCalibrationInput {
    base_url: String,
    node_id: String,
    moisture_raw_dry: u64,
    moisture_raw_wet: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartSetupWateringInput {
    base_url: String,
    zone_id: u64,
    node_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetupWateringStatusInput {
    base_url: String,
    zone_id: u64,
    node_id: Option<String>,
    idempotency_key: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetupActuatorProvisioningInput {
    base_url: String,
    logical_node_id: String,
    provisioning_operation_id: String,
    zone_external_id: Option<String>,
    board: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProvisionPicoInput {
    kind: String,
    wifi_ssid: String,
    wifi_password: String,
    mqtt_host: String,
    mqtt_port: u16,
    mqtt_username: String,
    mqtt_password: String,
    node_id: String,
    zone_id: String,
    publish_interval_ms: Option<u32>,
}

#[derive(Serialize)]
struct ProvisionPicoResult {
    kind: String,
    operation_id: String,
    serial_port: String,
    node_id: String,
    zone_id: String,
    channels: Vec<String>,
}

#[derive(Deserialize)]
struct ProvisionReadyPayload {
    role: String,
    node_id: String,
    zone_id: String,
    requires_provisioning: bool,
}

#[derive(Deserialize)]
struct ProvisionOkPayload {
    node_id: String,
    zone_id: String,
    #[serde(default)]
    channels: Vec<String>,
    rebooting: bool,
}

fn provisioned_channel_ids(kind: &str, payload: &ProvisionOkPayload) -> Result<Vec<String>, String> {
    if kind != "sensor" {
        return Ok(Vec::new());
    }

    let channels: Vec<String> = payload
        .channels
        .iter()
        .map(|channel| channel.trim().to_string())
        .filter(|channel| !channel.is_empty())
        .collect();
    let unique: std::collections::HashSet<&String> = channels.iter().collect();
    if channels.len() != EXPECTED_SENSOR_CHANNEL_COUNT || unique.len() != EXPECTED_SENSOR_CHANNEL_COUNT {
        return Err(format!(
            "sensor provisioning acknowledgement must contain {} unique channel ids, got {}",
            EXPECTED_SENSOR_CHANNEL_COUNT,
            channels.len()
        ));
    }

    Ok(channels)
}

#[derive(Serialize)]
struct PicoRuntimeDiagnostics {
    serial_port: Option<String>,
    category: String,
    summary: String,
    detail: String,
    recent_lines: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PicoRuntimeDiagnosticsInput {
    kind: String,
    timeout_ms: Option<u64>,
}

fn firmware_filename(kind: &str, board: &str) -> Result<&'static str, String> {
    match (kind, board) {
        ("sensor", "pico_w") => Ok("pico_w_sensor_node.uf2"),
        ("sensor", "pico2_w") => Ok("pico2_w_sensor_node.uf2"),
        ("actuator", "pico_w") => Ok("pico_w_actuator_node.uf2"),
        ("actuator", "pico2_w") => Ok("pico2_w_actuator_node.uf2"),
        _ => Err(format!(
            "unsupported firmware kind/board combination: {kind}/{board}"
        )),
    }
}

fn expected_boot_volume(board: &str) -> Result<&'static str, String> {
    match board {
        "pico_w" => Ok("RPI-RP2"),
        "pico2_w" => Ok("RP2350"),
        _ => Err(format!("unsupported board: {board}")),
    }
}

fn candidate_volume_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();

    #[cfg(target_os = "macos")]
    {
        roots.push(PathBuf::from("/Volumes"));
    }

    #[cfg(target_os = "linux")]
    {
        if let Ok(home) = std::env::var("HOME") {
            let home = PathBuf::from(home);
            roots.push(home.join("media"));
            if let Some(user) = home.file_name() {
                roots.push(PathBuf::from("/media").join(user));
                roots.push(PathBuf::from("/run/media").join(user));
            }
        }
    }

    roots
}

fn infer_board(volume_name: &str) -> Option<&'static str> {
    match volume_name {
        "RPI-RP2" => Some("pico_w"),
        "RP2350" => Some("pico2_w"),
        _ => None,
    }
}

fn scan_bootsel_devices() -> Vec<BootselDevice> {
    let mut devices = Vec::new();

    for root in candidate_volume_roots() {
        if !root.exists() {
            continue;
        }

        let Ok(entries) = fs::read_dir(root) else {
            continue;
        };

        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if !file_type.is_dir() {
                continue;
            }

            let volume_name = entry.file_name().to_string_lossy().to_string();
            let Some(board) = infer_board(&volume_name) else {
                continue;
            };

            devices.push(BootselDevice {
                board: board.to_string(),
                volume_name,
                mount_path: entry.path().display().to_string(),
            });
        }
    }

    devices.sort_by(|left, right| {
        left.board
            .cmp(&right.board)
            .then(left.mount_path.cmp(&right.mount_path))
    });
    devices
}

fn resolve_single_device(board: &str) -> Result<BootselDevice, String> {
    let matching: Vec<_> = scan_bootsel_devices()
        .into_iter()
        .filter(|device| device.board == board)
        .collect();

    match matching.len() {
        0 => Err(format!("no mounted {board} BOOTSEL device detected")),
        1 => Ok(matching.into_iter().next().unwrap()),
        _ => Err(format!(
            "multiple {board} BOOTSEL devices detected: {}",
            matching
                .iter()
                .map(|device| device.mount_path.clone())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

fn repo_bundle_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("firmware-bundles")
}

fn resolve_firmware_path(app: &AppHandle, filename: &str) -> Result<PathBuf, String> {
    if let Ok(bundle_root) = std::env::var("VG_FIRMWARE_BUNDLE_ROOT") {
        let candidate = PathBuf::from(bundle_root).join(filename);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    if let Ok(resource_dir) = app.path().resource_dir() {
        let candidate = resource_dir.join("firmware-bundles").join(filename);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    let candidate = repo_bundle_root().join(filename);
    if candidate.is_file() {
        return Ok(candidate);
    }

    Err(format!("firmware bundle not found: {filename}"))
}

fn deserialize_f64ish<'de, D>(deserializer: D) -> Result<f64, D::Error>
where
    D: Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    match value {
        serde_json::Value::Number(number) => number
            .as_f64()
            .ok_or_else(|| serde::de::Error::custom("invalid numeric value")),
        serde_json::Value::String(text) => text
            .parse::<f64>()
            .map_err(|_| serde::de::Error::custom(format!("invalid numeric string: {text}"))),
        other => Err(serde::de::Error::custom(format!(
            "expected number or numeric string, got {other}"
        ))),
    }
}

fn deserialize_option_f64ish<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    match value {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::Number(number)) => number
            .as_f64()
            .map(Some)
            .ok_or_else(|| serde::de::Error::custom("invalid numeric value")),
        Some(serde_json::Value::String(text)) => {
            if text.trim().is_empty() {
                Ok(None)
            } else {
                text.parse::<f64>()
                    .map(Some)
                    .map_err(|_| serde::de::Error::custom(format!("invalid numeric string: {text}")))
            }
        }
        Some(other) => Err(serde::de::Error::custom(format!(
            "expected number, numeric string, or null, got {other}"
        ))),
    }
}

fn parse_http_url(url: &str) -> Result<(String, String, u16, String), String> {
    let normalized = if url.starts_with("http://") || url.starts_with("https://") {
        url.to_string()
    } else {
        format!("http://{url}")
    };

    if normalized.starts_with("https://") {
        return Err("https probing is not supported for local Pi discovery".to_string());
    }

    let without_scheme = normalized
        .strip_prefix("http://")
        .ok_or_else(|| format!("unsupported URL: {normalized}"))?;

    let (host_port, path_suffix) = match without_scheme.split_once('/') {
        Some((host_port, remainder)) => (host_port, format!("/{remainder}")),
        None => (without_scheme, "/".to_string()),
    };

    if host_port.is_empty() {
        return Err("missing host in Pi URL".to_string());
    }

    let (host, port) = match host_port.rsplit_once(':') {
        Some((host, raw_port)) if !host.contains(']') => {
            let port = raw_port
                .parse::<u16>()
                .map_err(|_| format!("invalid port in Pi URL: {raw_port}"))?;
            (host.to_string(), port)
        }
        _ => (host_port.to_string(), 80),
    };

    Ok((normalized, host, port, path_suffix))
}

fn connect_with_timeout(addresses: impl Iterator<Item = SocketAddr>) -> Result<TcpStream, String> {
    let timeout = Duration::from_secs(2);
    let mut last_error = None;

    for address in addresses {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(stream) => {
                let _ = stream.set_read_timeout(Some(timeout));
                let _ = stream.set_write_timeout(Some(timeout));
                return Ok(stream);
            }
            Err(error) => {
                last_error = Some(format!("{address}: {error}"));
            }
        }
    }

    match last_error {
        Some(error) => Err(format!("could not connect to the Pi over HTTP: {error}")),
        None => Err("could not connect to the Pi over HTTP".to_string()),
    }
}

fn resolve_ipv4_host(host: &str, port: u16) -> Result<String, String> {
    if host.parse::<std::net::Ipv4Addr>().is_ok() {
        return Ok(host.to_string());
    }

    let addresses = (host, port)
        .to_socket_addrs()
        .map_err(|error| format!("could not resolve {host}:{port}: {error}"))?;

    for address in addresses {
        if let SocketAddr::V4(ipv4) = address {
            return Ok(ipv4.ip().to_string());
        }
    }

    Err(format!("could not resolve an IPv4 address for {host}"))
}

fn candidate_serial_ports() -> Result<Vec<String>, String> {
    let ports = available_ports().map_err(|error| format!("could not list serial ports: {error}"))?;
    let mut candidates: BTreeMap<String, String> = BTreeMap::new();

    for port in ports {
        let keep = match &port.port_type {
            SerialPortType::UsbPort(_) => true,
            _ => false,
        };

        if keep {
            let port_name = port.port_name;
            let key = normalized_serial_port_key(&port_name);
            match candidates.get(&key) {
                Some(existing) if existing.starts_with("/dev/cu.") => {}
                _ => {
                    candidates.insert(key, port_name);
                }
            }
        }
    }

    Ok(candidates.into_values().collect())
}

fn normalized_serial_port_key(port_name: &str) -> String {
    if let Some(stripped) = port_name.strip_prefix("/dev/cu.") {
        return format!("/dev/tty.{stripped}");
    }

    port_name.to_string()
}

fn wait_for_single_serial_port(timeout: Duration) -> Result<String, String> {
    let start = Instant::now();

    while start.elapsed() < timeout {
        let ports = candidate_serial_ports()?;
        if ports.len() == 1 {
            return Ok(ports[0].clone());
        }
        if ports.len() > 1 {
            return Err(format!(
                "multiple serial devices detected after flash: {}",
                ports.join(", ")
            ));
        }

        thread::sleep(Duration::from_millis(500));
    }

    Err("timed out waiting for the Pico USB serial port after flash".to_string())
}

fn read_serial_line(port: &mut dyn serialport::SerialPort, timeout: Duration) -> Result<Option<String>, String> {
    let start = Instant::now();
    let mut buffer = Vec::new();
    let mut byte = [0u8; 1];

    while start.elapsed() < timeout {
        match port.read(&mut byte) {
            Ok(1) => {
                if byte[0] == b'\n' {
                    let line = String::from_utf8_lossy(&buffer).trim().to_string();
                    return Ok(Some(line));
                }
                if byte[0] != b'\r' {
                    buffer.push(byte[0]);
                }
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::TimedOut => {}
            Err(error) => return Err(format!("serial read failed: {error}")),
        }
    }

    if buffer.is_empty() {
        Ok(None)
    } else {
        Ok(Some(String::from_utf8_lossy(&buffer).trim().to_string()))
    }
}

fn collect_serial_lines(port_name: &str, timeout: Duration) -> Result<Vec<String>, String> {
    let mut port = serialport::new(port_name, 115_200)
        .timeout(Duration::from_millis(250))
        .open()
        .map_err(|error| format!("could not open {port_name}: {error}"))?;

    let _ = port.clear(ClearBuffer::All);
    let deadline = Instant::now() + timeout;
    let mut lines = Vec::new();

    while Instant::now() < deadline {
        if let Some(line) = read_serial_line(port.as_mut(), Duration::from_millis(500))? {
            if !line.is_empty() {
                lines.push(line);
            }
        }
    }

    Ok(lines)
}

fn runtime_diagnostics_from_lines(kind: &str, port_name: &str, lines: Vec<String>) -> PicoRuntimeDiagnostics {
    let contains = |needle: &str| lines.iter().any(|line| line.contains(needle));
    let recent_lines = lines.iter().rev().take(12).cloned().collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>();

    if contains("[sensors] begin failed at addr=") {
        return PicoRuntimeDiagnostics {
            serial_port: Some(port_name.to_string()),
            category: "sensor_hardware_missing".to_string(),
            summary: "The sensor Pico booted, but the moisture probe did not respond.".to_string(),
            detail: "Move the sensor Pico onto the real probe hardware and check the Seesaw wiring, power, and I2C address before retrying.".to_string(),
            recent_lines,
        };
    }

    if contains("[wifi] failed:") {
        return PicoRuntimeDiagnostics {
            serial_port: Some(port_name.to_string()),
            category: "wifi_connection_failed".to_string(),
            summary: "The Pico could not join Wi‑Fi with the saved network settings.".to_string(),
            detail: "Recheck the Pico Wi‑Fi SSID/password in Step 2, then reprovision the board. If the SSID is correct, verify the board has signal where it will run.".to_string(),
            recent_lines,
        };
    }

    if contains("[mqtt_cb] not accepted") {
        return PicoRuntimeDiagnostics {
            serial_port: Some(port_name.to_string()),
            category: "mqtt_auth_failed".to_string(),
            summary: "The Pico reached the broker but the MQTT login was rejected.".to_string(),
            detail: "Refresh the Pi connection in Step 1 and save the connection settings again so the installer reprovisions the Pico with the Pi's current broker credentials.".to_string(),
            recent_lines,
        };
    }

    if contains("[mqtt] broker discovery timed out") {
        return PicoRuntimeDiagnostics {
            serial_port: Some(port_name.to_string()),
            category: "mqtt_broker_unreachable".to_string(),
            summary: "The Pico joined Wi‑Fi but could not discover or reach the Pi's MQTT broker.".to_string(),
            detail: "Verify the Pi is online, the Victory Garden services are running, and the Pico is on the same network segment as the Pi.".to_string(),
            recent_lines,
        };
    }

    if contains("[mqtt] connecting to ") || contains("[mqtt] disconnected err=") || contains("[mqtt] mqtt connect failed") {
        return PicoRuntimeDiagnostics {
            serial_port: Some(port_name.to_string()),
            category: "mqtt_connection_failed".to_string(),
            summary: "The Pico joined Wi‑Fi but could not complete MQTT setup.".to_string(),
            detail: "Verify the Pi broker is reachable at the saved host/port and reprovision the Pico if the Pi or broker credentials changed.".to_string(),
            recent_lines,
        };
    }

    if contains("[wifi] connected") && kind == "sensor" {
        return PicoRuntimeDiagnostics {
            serial_port: Some(port_name.to_string()),
            category: "sensor_waiting_for_hardware".to_string(),
            summary: "The sensor Pico joined Wi‑Fi, but it still has not reported usable sensor data.".to_string(),
            detail: "Make sure the flashed sensor Pico is connected to the real probe hardware before waiting for it to appear in Victory Garden.".to_string(),
            recent_lines,
        };
    }

    PicoRuntimeDiagnostics {
        serial_port: Some(port_name.to_string()),
        category: "unknown".to_string(),
        summary: "The Pico produced runtime logs, but they did not match a known failure pattern.".to_string(),
        detail: "Review the recent Pico logs shown below, then retry after checking Wi‑Fi, MQTT, and the hardware wiring.".to_string(),
        recent_lines,
    }
}

fn timestamp_string() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{}", now.as_secs(), now.subsec_millis())
}

fn operation_id(prefix: &str) -> String {
    format!("{}-{}", prefix, timestamp_string().replace('.', "-"))
}

fn installer_data_dir(app: &AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_local_data_dir()
        .or_else(|_| app.path().app_data_dir())
        .map_err(|error| format!("could not resolve installer data directory: {error}"))
}

fn is_disappearing_serial_error(error: &str) -> bool {
    let lower = error.to_lowercase();
    lower.contains("serial read failed")
        && (lower.contains("no such file")
            || lower.contains("resource busy")
            || lower.contains("device not configured")
            || lower.contains("input/output error")
            || lower.contains("broken pipe"))
}

fn should_retry_provision_error(error: &str) -> bool {
    let lower = error.to_lowercase();
    lower.contains("timed out waiting for the pico usb serial port after flash")
        || (lower.contains("could not open /dev") && (lower.contains("no such file") || lower.contains("resource busy") || lower.contains("device not configured")))
        || lower.contains("did not receive provisioning prompt from pico")
        || lower.contains("timed out waiting for provisioning confirmation")
        || lower.contains("invalid provisioning ready payload")
        || lower.contains("invalid provisioning acknowledgement payload")
        || lower.contains("unexpected provisioning acknowledgement")
        || lower.contains("unexpected provisioning prompt")
        || is_disappearing_serial_error(error)
}

fn installer_logs_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = installer_data_dir(app)?.join(INSTALLER_LOG_DIR);
    fs::create_dir_all(&dir)
        .map_err(|error| format!("could not create installer log directory {}: {error}", dir.display()))?;
    Ok(dir)
}

fn rotate_log_if_needed(log_path: &Path) -> Result<(), String> {
    let metadata = match fs::metadata(log_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!("could not inspect installer log {}: {error}", log_path.display()))
        }
    };

    if metadata.len() < INSTALLER_LOG_MAX_BYTES {
        return Ok(());
    }

    let rotated_path = log_path.with_file_name(INSTALLER_LOG_ROTATED_FILE);
    if rotated_path.exists() {
        fs::remove_file(&rotated_path)
            .map_err(|error| format!("could not remove rotated installer log {}: {error}", rotated_path.display()))?;
    }

    fs::rename(log_path, &rotated_path).map_err(|error| {
        format!(
            "could not rotate installer log {} -> {}: {error}",
            log_path.display(),
            rotated_path.display()
        )
    })?;
    Ok(())
}

fn append_installer_log_entry(app: &AppHandle, entry: &InstallerLogEntryInput) -> Result<(), String> {
    let logs_dir = installer_logs_dir(app)?;
    let log_path = logs_dir.join(INSTALLER_LOG_FILE);
    rotate_log_if_needed(&log_path)?;

    let line = json!({
        "timestamp": timestamp_string(),
        "level": entry.level,
        "category": entry.category,
        "action": entry.action,
        "message": entry.message,
        "details": entry.details,
        "installer_version": env!("CARGO_PKG_VERSION"),
        "platform": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
    })
    .to_string();

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|error| format!("could not open installer log {}: {error}", log_path.display()))?;
    file.write_all(line.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .map_err(|error| format!("could not append installer log {}: {error}", log_path.display()))?;
    Ok(())
}

fn log_internal(
    app: &AppHandle,
    level: &str,
    category: &str,
    action: &str,
    message: &str,
    details: Option<serde_json::Value>,
) {
    let _ = append_installer_log_entry(
        app,
        &InstallerLogEntryInput {
            level: level.to_string(),
            category: category.to_string(),
            action: action.to_string(),
            message: message.to_string(),
            details,
        },
    );
}

fn copy_if_exists(source: &Path, target: &Path) -> Result<(), String> {
    if !source.exists() {
        return Ok(());
    }

    fs::copy(source, target).map_err(|error| {
        format!(
            "could not copy {} to {}: {error}",
            source.display(),
            target.display()
        )
    })?;
    Ok(())
}

fn create_support_zip(bundle_dir: &Path, zip_path: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("ditto");
        command.args(["-c", "-k", "--sequesterRsrc", "--keepParent"]);
        command.arg(bundle_dir);
        command.arg(zip_path);
        command
    };

    #[cfg(target_os = "linux")]
    let mut command = {
        let parent = bundle_dir.parent().ok_or_else(|| {
            format!("could not determine parent directory for {}", bundle_dir.display())
        })?;
        let name = bundle_dir
            .file_name()
            .ok_or_else(|| format!("could not determine export directory name for {}", bundle_dir.display()))?;
        let mut command = Command::new("zip");
        command.current_dir(parent);
        command.args(["-r", zip_path.to_string_lossy().as_ref(), name.to_string_lossy().as_ref()]);
        command
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("powershell");
        command.args([
            "-NoProfile",
            "-Command",
            &format!(
                "Compress-Archive -Path '{}' -DestinationPath '{}' -Force",
                bundle_dir.display(),
                zip_path.display()
            ),
        ]);
        command
    };

    let status = command
        .status()
        .map_err(|error| format!("could not create support ZIP {}: {error}", zip_path.display()))?;

    if !status.success() {
        return Err(format!(
            "support ZIP creation failed for {} with exit status {}",
            zip_path.display(),
            status
        ));
    }

    Ok(())
}

fn flash_io_error(action: &str, target_path: &Path, error: std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::NotFound | std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::UnexpectedEof => {
            format!(
                "the BOOTSEL drive disappeared while {} {}: {}",
                action,
                target_path.display(),
                error
            )
        }
        _ => format!("could not {} {}: {}", action, target_path.display(), error),
    }
}

fn api_url_from_base(base_url: &str, path: &str) -> Result<String, String> {
    let (_, host, port, _) = parse_http_url(base_url)?;
    Ok(format!("http://{host}:{port}{path}"))
}

fn encode_query_value(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        let keep = matches!(byte, b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~');
        if keep {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn http_request(url: &str, method: &str, body: Option<&str>, content_type: Option<&str>) -> Result<(u16, String), String> {
    let (normalized_url, host, port, path) = parse_http_url(url)?;
    let addresses = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|error| format!("could not resolve {host}:{port}: {error}"))?;
    let mut stream = connect_with_timeout(addresses)?;
    let payload = body.unwrap_or("");
    let content_type_header = content_type.unwrap_or("application/json");

    let request = if body.is_some() {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: {content_type_header}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            payload.len(),
            payload
        )
    } else {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
        )
    };

    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("could not send HTTP request to {normalized_url}: {error}"))?;

    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|error| format!("could not read HTTP response from {normalized_url}: {error}"))?;

    let (header_block, response_body) = response
        .split_once("\r\n\r\n")
        .ok_or_else(|| format!("invalid HTTP response from {normalized_url}"))?;
    let status_line = header_block
        .lines()
        .next()
        .ok_or_else(|| format!("empty HTTP response from {normalized_url}"))?;
    let status_code = status_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| format!("invalid HTTP response from {normalized_url}: {status_line}"))?
        .parse::<u16>()
        .map_err(|_| format!("invalid HTTP status from {normalized_url}: {status_line}"))?;

    Ok((status_code, response_body.to_string()))
}

fn decode_json_response<T: DeserializeOwned>(status_code: u16, body: &str, url: &str) -> Result<T, String> {
    if (200..300).contains(&status_code) {
        return serde_json::from_str(body)
            .map_err(|error| format!("could not decode JSON response from {url}: {error}"));
    }

    if let Ok(error_response) = serde_json::from_str::<ErrorResponse>(body) {
        return Err(error_response.errors.join(", "));
    }

    Err(format!("HTTP {status_code} from {url}"))
}

// Lets the JS side derive its expectation from this one constant instead of
// hardcoding its own copy of the sensor channel count.
#[tauri::command]
fn expected_sensor_channel_count() -> usize {
    EXPECTED_SENSOR_CHANNEL_COUNT
}

#[tauri::command]
fn write_installer_log(app: AppHandle, entry: InstallerLogEntryInput) -> Result<(), String> {
    append_installer_log_entry(&app, &entry)
}

#[tauri::command]
fn export_support_bundle(app: AppHandle, input: ExportSupportBundleInput) -> Result<SupportBundleExportResult, String> {
    let base_dir = installer_data_dir(&app)?.join(INSTALLER_SUPPORT_DIR);
    fs::create_dir_all(&base_dir).map_err(|error| {
        format!(
            "could not create installer support bundle directory {}: {error}",
            base_dir.display()
        )
    })?;

    let timestamp = timestamp_string().replace('.', "-");
    let bundle_dir = base_dir.join(format!("support-bundle-{timestamp}"));
    fs::create_dir_all(&bundle_dir).map_err(|error| {
        format!(
            "could not create support bundle directory {}: {error}",
            bundle_dir.display()
        )
    })?;

    let manifest = json!({
        "generated_at": timestamp_string(),
        "installer_version": env!("CARGO_PKG_VERSION"),
        "tauri_version": TAURI_RUNTIME_VERSION,
        "platform": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
    });

    fs::write(
        bundle_dir.join("runtime-info.json"),
        serde_json::to_string_pretty(&manifest)
            .map_err(|error| format!("could not encode runtime info JSON: {error}"))?,
    )
    .map_err(|error| format!("could not write runtime info: {error}"))?;

    fs::write(
        bundle_dir.join("setup-state.json"),
        serde_json::to_string_pretty(&input.setup_state)
            .map_err(|error| format!("could not encode setup state JSON: {error}"))?,
    )
    .map_err(|error| format!("could not write setup state: {error}"))?;

    let logs_dir = installer_logs_dir(&app)?;
    let exported_logs_dir = bundle_dir.join("logs");
    fs::create_dir_all(&exported_logs_dir).map_err(|error| {
        format!(
            "could not create exported log directory {}: {error}",
            exported_logs_dir.display()
        )
    })?;
    copy_if_exists(
        &logs_dir.join(INSTALLER_LOG_FILE),
        &exported_logs_dir.join(INSTALLER_LOG_FILE),
    )?;
    copy_if_exists(
        &logs_dir.join(INSTALLER_LOG_ROTATED_FILE),
        &exported_logs_dir.join(INSTALLER_LOG_ROTATED_FILE),
    )?;

    let zip_path = bundle_dir.with_extension("zip");
    if zip_path.exists() {
        fs::remove_file(&zip_path)
            .map_err(|error| format!("could not remove old support ZIP {}: {error}", zip_path.display()))?;
    }
    create_support_zip(&bundle_dir, &zip_path)?;

    log_internal(
        &app,
        "info",
        "support",
        "export_bundle",
        "Created a diagnostic support bundle.",
        Some(json!({
            "bundle_dir": bundle_dir.display().to_string(),
            "zip_path": zip_path.display().to_string(),
        })),
    );

    Ok(SupportBundleExportResult {
        zip_path: zip_path.display().to_string(),
        bundle_dir: bundle_dir.display().to_string(),
    })
}

#[tauri::command]
fn detect_bootsel_devices() -> Result<Vec<BootselDevice>, String> {
    Ok(scan_bootsel_devices())
}

#[tauri::command]
fn probe_victory_garden(url: String) -> Result<ProbeResult, String> {
    let (normalized_url, host, port, path) = parse_http_url(&url)?;
    let addresses = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|error| format!("could not resolve {host}:{port}: {error}"))?;
    let mut stream = connect_with_timeout(addresses)?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
    );

    stream
        .write_all(request.as_bytes())
        .map_err(|error| format!("could not send HTTP request to {normalized_url}: {error}"))?;

    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|error| format!("could not read HTTP response from {normalized_url}: {error}"))?;

    let first_line = response
        .lines()
        .next()
        .ok_or_else(|| format!("empty HTTP response from {normalized_url}"))?;
    let status_code = first_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| format!("invalid HTTP response from {normalized_url}: {first_line}"))?
        .parse::<u16>()
        .map_err(|_| format!("invalid HTTP status from {normalized_url}: {first_line}"))?;

    if matches!(status_code, 200 | 301 | 302 | 303 | 307 | 308) {
        return Ok(ProbeResult {
            url: normalized_url,
            status_code,
        });
    }

    Err(format!(
        "Victory Garden did not respond successfully at {normalized_url} (HTTP {status_code})"
    ))
}

#[tauri::command]
fn fetch_setup_bootstrap(base_url: String) -> Result<SetupBootstrapResponse, String> {
    let url = api_url_from_base(&base_url, "/setup_api/bootstrap")?;
    let (status_code, body) = http_request(&url, "GET", None, None)?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn save_setup_connection(input: SaveConnectionInput) -> Result<SetupConnectionResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/connection")?;
    let payload = json!({
        "connection_setting": {
            "mqtt_host": input.mqtt_host,
            "mqtt_port": input.mqtt_port,
            "mqtt_username": input.mqtt_username,
            "mqtt_password": input.mqtt_password,
            "irrigation_line_count": input.irrigation_line_count
        }
    })
    .to_string();
    let (status_code, body) = http_request(&url, "PATCH", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn create_setup_crop_profile(input: CreateCropProfileInput) -> Result<SetupCropProfileResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/crop_profile")?;
    let payload = json!({
        "crop_profile": {
            "crop_name": input.crop_name,
            "dry_threshold": input.dry_threshold,
            "max_pulse_runtime_sec": input.max_pulse_runtime_sec,
            "daily_max_runtime_sec": input.daily_max_runtime_sec
        }
    })
    .to_string();
    let (status_code, body) = http_request(&url, "POST", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn save_setup_zone(input: SaveZoneInput) -> Result<SetupZoneResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/zone")?;
    let payload = json!({
        "zone": {
            "name": input.name,
            "publish_interval_ms": u32::from(input.publish_interval_hours) * 3_600_000,
            "active": true
        }
    })
    .to_string();
    let (status_code, body) = http_request(&url, "PATCH", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn fetch_setup_node_status(input: SetupNodeStatusInput) -> Result<SetupNodeStatusResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/node_status")?;
    let query_url = format!("{url}?node_id={}", encode_query_value(&input.node_id));
    let (status_code, body) = http_request(&query_url, "GET", None, None)?;
    decode_json_response(status_code, &body, &query_url)
}

#[tauri::command]
fn assign_setup_node(input: AssignSetupNodeInput) -> Result<SetupAssignNodeResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/assign_node")?;
    let payload = json!({
        "node_id": input.node_id,
        "zone_id": input.zone_id
    })
    .to_string();
    let (status_code, body) = http_request(&url, "POST", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn update_setup_node(input: UpdateSetupNodeInput) -> Result<SetupUpdateNodeResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/node")?;
    let payload = json!({
        "node_id": input.node_id,
        "name": input.name,
        "crop_profile_id": input.crop_profile_id,
        "irrigation_line": input.irrigation_line
    })
    .to_string();
    let (status_code, body) = http_request(&url, "PATCH", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn request_setup_reading(input: RequestSetupReadingInput) -> Result<SetupRequestReadingResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/request_reading")?;
    let payload = json!({
        "node_id": input.node_id
    })
    .to_string();
    let (status_code, body) = http_request(&url, "POST", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn fetch_setup_reading_status(input: SetupReadingStatusInput) -> Result<SetupReadingStatusResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/reading_status")?;
    let query_url = format!(
        "{url}?node_id={}&since={}",
        encode_query_value(&input.node_id),
        encode_query_value(&input.since)
    );
    let (status_code, body) = http_request(&query_url, "GET", None, None)?;
    decode_json_response(status_code, &body, &query_url)
}

#[tauri::command]
fn save_setup_calibration(input: SaveSetupCalibrationInput) -> Result<SetupCalibrationResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/calibration")?;
    let payload = json!({
        "node_id": input.node_id,
        "moisture_raw_dry": input.moisture_raw_dry,
        "moisture_raw_wet": input.moisture_raw_wet
    })
    .to_string();
    let (status_code, body) = http_request(&url, "PATCH", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn start_setup_watering(input: StartSetupWateringInput) -> Result<SetupStartWateringResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/start_watering")?;
    let payload = json!({
        "zone_id": input.zone_id,
        "node_id": input.node_id
    })
    .to_string();
    let (status_code, body) = http_request(&url, "POST", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn fetch_setup_watering_status(input: SetupWateringStatusInput) -> Result<SetupWateringStatusResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/watering_status")?;
    let query_url = format!(
        "{url}?zone_id={}&node_id={}&idempotency_key={}",
        input.zone_id,
        encode_query_value(input.node_id.as_deref().unwrap_or("")),
        encode_query_value(&input.idempotency_key)
    );
    let (status_code, body) = http_request(&query_url, "GET", None, None)?;
    decode_json_response(status_code, &body, &query_url)
}

#[tauri::command]
fn record_setup_actuator_provisioning(
    input: SetupActuatorProvisioningInput,
) -> Result<SetupActuatorProvisioningResponse, String> {
    let url = api_url_from_base(&input.base_url, "/setup_api/actuator_provisioning")?;
    let payload = json!({
        "actuator_provisioning": {
            "logical_node_id": input.logical_node_id,
            "provisioning_operation_id": input.provisioning_operation_id,
            "zone_external_id": input.zone_external_id,
            "board": input.board
        }
    })
    .to_string();
    let (status_code, body) = http_request(&url, "POST", Some(&payload), Some("application/json"))?;
    decode_json_response(status_code, &body, &url)
}

#[tauri::command]
fn collect_pico_runtime_diagnostics(input: PicoRuntimeDiagnosticsInput) -> Result<PicoRuntimeDiagnostics, String> {
    let timeout = Duration::from_millis(input.timeout_ms.unwrap_or(8000).clamp(1000, 20000));
    let ports = candidate_serial_ports()?;

    match ports.as_slice() {
        [] => Ok(PicoRuntimeDiagnostics {
            serial_port: None,
            category: "serial_unavailable".to_string(),
            summary: "No Pico serial port is connected to this computer right now.".to_string(),
            detail: "If the Pico was moved to its real hardware or power source, the installer cannot read live USB logs from it. Check Wi‑Fi, MQTT, and the hardware connection on the running setup instead.".to_string(),
            recent_lines: Vec::new(),
        }),
        [port_name] => {
            let lines = collect_serial_lines(port_name, timeout)?;
            if lines.is_empty() {
                return Ok(PicoRuntimeDiagnostics {
                    serial_port: Some(port_name.clone()),
                    category: "serial_idle".to_string(),
                    summary: "The Pico serial port is connected, but it did not emit any diagnostic logs.".to_string(),
                    detail: "Leave the Pico attached and powered, then retry. If it still stays silent, erase and reflash it before trying again.".to_string(),
                    recent_lines: Vec::new(),
                });
            }

            Ok(runtime_diagnostics_from_lines(&input.kind, port_name, lines))
        }
        _ => Ok(PicoRuntimeDiagnostics {
            serial_port: None,
            category: "multiple_serial_devices".to_string(),
            summary: "More than one Pico serial device is attached to this computer.".to_string(),
            detail: "Leave only the board you want to diagnose connected over USB, then retry the setup step.".to_string(),
            recent_lines: ports,
        }),
    }
}

#[tauri::command]
fn provision_pico(app: AppHandle, input: ProvisionPicoInput) -> Result<ProvisionPicoResult, String> {
    const MAX_PROVISION_ATTEMPTS: u8 = 3;
    const SERIAL_WAIT_TIMEOUT: Duration = Duration::from_secs(20);
    const READY_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
    const ACK_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
    const RETRY_DELAY: Duration = Duration::from_millis(1200);

    let provisioning_operation_id = operation_id("provision");
    log_internal(
        &app,
        "info",
        "provisioning",
        "start",
        "Starting Pico serial provisioning.",
        Some(json!({
            "operation_id": &provisioning_operation_id,
            "kind": &input.kind,
            "node_id": &input.node_id,
            "zone_id": &input.zone_id,
            "mqtt_host": &input.mqtt_host,
            "mqtt_port": input.mqtt_port,
        })),
    );

    let mqtt_host = resolve_ipv4_host(&input.mqtt_host, input.mqtt_port)?;
    let payload = json!({
        "wifi_ssid": &input.wifi_ssid,
        "wifi_password": &input.wifi_password,
        "mqtt_host": mqtt_host,
        "mqtt_port": input.mqtt_port,
        "mqtt_username": &input.mqtt_username,
        "mqtt_password": &input.mqtt_password,
        "node_id": &input.node_id,
        "zone_id": &input.zone_id,
        "publish_interval_ms": input.publish_interval_ms
    });
    let command = format!("VG_PROVISION {}\n", payload);
    let mut last_error = String::new();

    for attempt in 1..=MAX_PROVISION_ATTEMPTS {
        log_internal(
            &app,
            "info",
            "provisioning",
            "attempt_start",
            "Starting a Pico provisioning attempt.",
            Some(json!({
                "operation_id": &provisioning_operation_id,
                "attempt": attempt,
                "max_attempts": MAX_PROVISION_ATTEMPTS,
                "kind": &input.kind,
                "node_id": &input.node_id,
            })),
        );

        let attempt_result: Result<ProvisionPicoResult, String> = (|| {
            let serial_port_name = wait_for_single_serial_port(SERIAL_WAIT_TIMEOUT)?;
            log_internal(
                &app,
                "info",
                "provisioning",
                "serial_port_detected",
                "Detected a single Pico serial port for provisioning.",
                Some(json!({
                    "operation_id": &provisioning_operation_id,
                    "attempt": attempt,
                    "serial_port": &serial_port_name,
                    "kind": &input.kind,
                    "node_id": &input.node_id,
                })),
            );

            let mut port = serialport::new(&serial_port_name, 115_200)
                .timeout(Duration::from_millis(250))
                .open()
                .map_err(|error| format!("could not open {serial_port_name}: {error}"))?;

            let _ = port.clear(ClearBuffer::All);

            let hello_deadline = std::time::Instant::now() + READY_WAIT_TIMEOUT;
            let mut last_identify_at = std::time::Instant::now() - Duration::from_secs(1);
            let mut ready_payload: Option<ProvisionReadyPayload> = None;
            while std::time::Instant::now() < hello_deadline {
                if last_identify_at.elapsed() >= Duration::from_millis(750) {
                    let _ = port.write_all(b"VG_IDENTIFY\n");
                    let _ = port.flush();
                    last_identify_at = std::time::Instant::now();
                }

                if let Some(line) = read_serial_line(port.as_mut(), Duration::from_millis(500))? {
                    if let Some(payload_text) = line.strip_prefix("VG_READY ") {
                        let parsed: ProvisionReadyPayload = serde_json::from_str(payload_text)
                            .map_err(|error| format!("invalid provisioning ready payload from {serial_port_name}: {error}"))?;
                        if parsed.role != input.kind {
                            return Err(format!(
                                "unexpected provisioning prompt from {serial_port_name}: expected role {} but device announced {}",
                                input.kind, parsed.role
                            ));
                        }
                        ready_payload = Some(parsed);
                        break;
                    }
                }
            }

            let ready_payload = ready_payload.ok_or_else(|| {
                format!("did not receive provisioning prompt from Pico on {serial_port_name}")
            })?;

            log_internal(
                &app,
                "info",
                "provisioning",
                "ready_received",
                "Received Pico provisioning prompt.",
                Some(json!({
                    "operation_id": &provisioning_operation_id,
                    "attempt": attempt,
                    "serial_port": &serial_port_name,
                    "reported_role": ready_payload.role,
                    "reported_node_id": ready_payload.node_id,
                    "reported_zone_id": ready_payload.zone_id,
                    "requires_provisioning": ready_payload.requires_provisioning,
                })),
            );

            port.write_all(command.as_bytes())
                .map_err(|error| format!("could not write provisioning command to {serial_port_name}: {error}"))?;
            port.flush()
                .map_err(|error| format!("could not flush provisioning command to {serial_port_name}: {error}"))?;
            log_internal(
                &app,
                "info",
                "provisioning",
                "payload_sent",
                "Sent provisioning payload to the Pico.",
                Some(json!({
                    "operation_id": &provisioning_operation_id,
                    "attempt": attempt,
                    "serial_port": &serial_port_name,
                    "kind": &input.kind,
                    "node_id": &input.node_id,
                    "zone_id": &input.zone_id,
                })),
            );

            let response_deadline = std::time::Instant::now() + ACK_WAIT_TIMEOUT;
            while std::time::Instant::now() < response_deadline {
                if let Some(line) = read_serial_line(port.as_mut(), Duration::from_millis(500))? {
                    if let Some(payload_text) = line.strip_prefix("VG_PROVISION_OK ") {
                        let ack_payload: ProvisionOkPayload = serde_json::from_str(payload_text)
                            .map_err(|error| format!("invalid provisioning acknowledgement payload from {serial_port_name}: {error}"))?;
                        if ack_payload.node_id != input.node_id || ack_payload.zone_id != input.zone_id {
                            return Err(format!(
                                "unexpected provisioning acknowledgement from {serial_port_name}: expected node {} zone {} but got node {} zone {}",
                                input.node_id, input.zone_id, ack_payload.node_id, ack_payload.zone_id
                            ));
                        }
                        let channels = provisioned_channel_ids(&input.kind, &ack_payload)?;
                        log_internal(
                            &app,
                            "info",
                            "provisioning",
                            "ack_received",
                            "Received Pico provisioning confirmation.",
                            Some(json!({
                                "operation_id": &provisioning_operation_id,
                                "attempt": attempt,
                                "serial_port": &serial_port_name,
                                "kind": &input.kind,
                                "node_id": &input.node_id,
                                "rebooting": ack_payload.rebooting,
                            })),
                        );
                        return Ok(ProvisionPicoResult {
                            kind: input.kind.clone(),
                            operation_id: provisioning_operation_id.clone(),
                            serial_port: serial_port_name,
                            node_id: input.node_id.clone(),
                            zone_id: input.zone_id.clone(),
                            channels,
                        });
                    }
                    if let Some(error) = line.strip_prefix("VG_PROVISION_ERROR ") {
                        log_internal(
                            &app,
                            "error",
                            "provisioning",
                            "ack_error",
                            "The Pico returned a provisioning error.",
                            Some(json!({
                                "operation_id": &provisioning_operation_id,
                                "attempt": attempt,
                                "serial_port": &serial_port_name,
                                "kind": &input.kind,
                                "node_id": &input.node_id,
                                "error": error,
                            })),
                        );
                        return Err(error.to_string());
                    }
                }
            }

            Err(format!(
                "timed out waiting for provisioning confirmation from {serial_port_name}"
            ))
        })();

        match attempt_result {
            Ok(result) => return Ok(result),
            Err(error) => {
                last_error = error;
                let retryable = should_retry_provision_error(&last_error);
                let will_retry = retryable && attempt < MAX_PROVISION_ATTEMPTS;
                log_internal(
                    &app,
                    if will_retry { "warn" } else { "error" },
                    "provisioning",
                    if will_retry { "attempt_retry" } else { "attempt_failed" },
                    if will_retry {
                        "Provisioning attempt failed, but the installer will retry."
                    } else {
                        "Provisioning attempt failed."
                    },
                    Some(json!({
                        "operation_id": &provisioning_operation_id,
                        "attempt": attempt,
                        "max_attempts": MAX_PROVISION_ATTEMPTS,
                        "retryable": retryable,
                        "error": &last_error,
                    })),
                );

                if !will_retry {
                    break;
                }

                thread::sleep(RETRY_DELAY);
            }
        }
    }

    Err(format!(
        "{} after {} provisioning attempts",
        last_error,
        MAX_PROVISION_ATTEMPTS
    ))
}

#[tauri::command]
async fn flash_firmware(
    app: AppHandle,
    kind: String,
    board: String,
) -> Result<FlashResult, String> {
    let flash_operation_id = operation_id("flash");
    log_internal(
        &app,
        "info",
        "flashing",
        "start",
        "Starting UF2 flash to a BOOTSEL device.",
        Some(json!({
            "operation_id": &flash_operation_id,
            "kind": &kind,
            "board": &board,
        })),
    );
    let filename = firmware_filename(&kind, &board)?;
    let expected_volume = expected_boot_volume(&board)?;
    let device = resolve_single_device(&board)?;

    if device.volume_name != expected_volume {
        return Err(format!(
            "detected volume '{}' does not match expected BOOTSEL drive '{}'",
            device.volume_name, expected_volume
        ));
    }

    let firmware_path = resolve_firmware_path(&app, filename)?;
    let target_path = Path::new(&device.mount_path).join(filename);

    let firmware_path_for_copy = firmware_path.clone();
    let target_path_for_copy = target_path.clone();
    tauri::async_runtime::spawn_blocking(move || -> Result<(), String> {
        let mut source = fs::File::open(&firmware_path_for_copy).map_err(|error| {
            format!(
                "could not open firmware bundle {}: {error}",
                firmware_path_for_copy.display()
            )
        })?;
        let mut destination = fs::File::create(&target_path_for_copy)
            .map_err(|error| flash_io_error("opening", &target_path_for_copy, error))?;

        let mut buffer = [0u8; 1024 * 64];
        loop {
            let bytes_read = source.read(&mut buffer).map_err(|error| {
                format!(
                    "could not read firmware bundle {}: {error}",
                    firmware_path_for_copy.display()
                )
            })?;
            if bytes_read == 0 {
                break;
            }

            destination
                .write_all(&buffer[..bytes_read])
                .map_err(|error| flash_io_error("writing", &target_path_for_copy, error))?;
        }

        destination
            .flush()
            .map_err(|error| flash_io_error("flushing", &target_path_for_copy, error))?;
        destination
            .sync_all()
            .map_err(|error| flash_io_error("finishing", &target_path_for_copy, error))?;
        Ok(())
    })
    .await
    .map_err(|error| format!("flash task failed: {error}"))??;

    log_internal(
        &app,
        "info",
        "flashing",
        "success",
        "Completed UF2 flash to the BOOTSEL device.",
        Some(json!({
            "operation_id": &flash_operation_id,
            "kind": &kind,
            "board": &board,
            "filename": filename,
            "mount_path": &device.mount_path,
        })),
    );

    Ok(FlashResult {
        board,
        kind,
        operation_id: flash_operation_id,
        flashed_filename: filename.to_string(),
        flashed_path: target_path.display().to_string(),
        device,
    })
}

#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    let target = if url.trim().is_empty() {
        DEFAULT_WIZARD_URL.to_string()
    } else {
        url
    };

    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg(&target);
        command
    };

    #[cfg(target_os = "linux")]
    let mut command = {
        let mut command = Command::new("xdg-open");
        command.arg(&target);
        command
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("cmd");
        command.args(["/C", "start", "", &target]);
        command
    };

    command
        .status()
        .map_err(|error| format!("could not open {target}: {error}"))?;
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            expected_sensor_channel_count,
            write_installer_log,
            export_support_bundle,
            detect_bootsel_devices,
            probe_victory_garden,
            fetch_setup_bootstrap,
            save_setup_connection,
            create_setup_crop_profile,
            save_setup_zone,
            fetch_setup_node_status,
            assign_setup_node,
            update_setup_node,
            request_setup_reading,
            fetch_setup_reading_status,
            save_setup_calibration,
            start_setup_watering,
            fetch_setup_watering_status,
            record_setup_actuator_provisioning,
            collect_pico_runtime_diagnostics,
            provision_pico,
            flash_firmware,
            open_url
        ])
        .run(tauri::generate_context!())
        .expect("error while running Victory Garden desktop installer");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_http_url_adds_http_defaults() {
        let (normalized, host, port, path) = parse_http_url("victory-garden.local").unwrap();
        assert_eq!(normalized, "http://victory-garden.local");
        assert_eq!(host, "victory-garden.local");
        assert_eq!(port, 80);
        assert_eq!(path, "/");
    }

    #[test]
    fn parse_http_url_preserves_explicit_port_and_path() {
        let (normalized, host, port, path) =
            parse_http_url("http://192.168.4.33:3000/setup_api/bootstrap").unwrap();
        assert_eq!(normalized, "http://192.168.4.33:3000/setup_api/bootstrap");
        assert_eq!(host, "192.168.4.33");
        assert_eq!(port, 3000);
        assert_eq!(path, "/setup_api/bootstrap");
    }

    #[test]
    fn infer_board_maps_supported_bootsel_volume_names() {
        assert_eq!(infer_board("RPI-RP2"), Some("pico_w"));
        assert_eq!(infer_board("RP2350"), Some("pico2_w"));
        assert_eq!(infer_board("UNTITLED"), None);
    }

    #[test]
    fn normalized_serial_port_key_deduplicates_macos_modem_variants() {
        assert_eq!(
            normalized_serial_port_key("/dev/cu.usbmodem21101"),
            normalized_serial_port_key("/dev/tty.usbmodem21101")
        );
        assert_eq!(
            normalized_serial_port_key("/dev/cu.usbmodem21101"),
            "/dev/tty.usbmodem21101"
        );
        assert_eq!(
            normalized_serial_port_key("/dev/tty.usbmodem21101"),
            "/dev/tty.usbmodem21101"
        );
        assert_eq!(normalized_serial_port_key("/dev/ttyUSB0"), "/dev/ttyUSB0");
        assert_eq!(normalized_serial_port_key("/dev/ttyACM0"), "/dev/ttyACM0");
        assert_eq!(normalized_serial_port_key("COM3"), "COM3");
        assert_eq!(
            normalized_serial_port_key("/tmp/cu.usbmodem21101"),
            "/tmp/cu.usbmodem21101"
        );
    }

    #[test]
    fn provisioning_retry_classification_matches_serial_edge_cases() {
        assert!(is_disappearing_serial_error(
            "serial read failed: device not configured"
        ));
        assert!(should_retry_provision_error(
            "timed out waiting for the Pico USB serial port after flash"
        ));
        assert!(should_retry_provision_error(
            "invalid provisioning acknowledgement payload: missing field"
        ));
        assert!(!should_retry_provision_error(
            "VG_PROVISION_ERROR provisioning fields cannot be blank"
        ));
    }

    #[test]
    fn setup_status_carries_explicit_readiness_fields_to_frontend_json() {
        let parsed: SetupBootstrapResponse = serde_json::from_value(json!({
            "status": {
                "connection_ready": true,
                "first_zone_ready": false,
                "watering_targets_ready": true,
                "zone_ready": true,
                "detected_node_ready": false,
                "assigned_node_ready": false,
                "reading_ready": false,
                "calibration_ready": false,
                "watering_ready": false
            },
            "connection_setting": {},
            "crop_profiles": [],
            "first_zone": null,
            "detected_node": null,
            "assigned_node": null
        }))
        .unwrap();

        let frontend_json = serde_json::to_value(parsed).unwrap();
        let status = frontend_json.get("status").unwrap();
        assert_eq!(status.get("first_zone_ready").unwrap(), false);
        assert_eq!(status.get("watering_targets_ready").unwrap(), true);
        assert_eq!(status.get("zone_ready").unwrap(), true);
    }

    #[test]
    fn setup_status_omits_explicit_readiness_fields_for_legacy_bootstrap() {
        let parsed: SetupBootstrapResponse = serde_json::from_value(json!({
            "status": {
                "connection_ready": true,
                "zone_ready": true,
                "detected_node_ready": false,
                "assigned_node_ready": false,
                "reading_ready": false,
                "calibration_ready": false,
                "watering_ready": false
            },
            "connection_setting": {},
            "crop_profiles": [],
            "first_zone": null,
            "detected_node": null,
            "assigned_node": null
        }))
        .unwrap();

        let frontend_json = serde_json::to_value(parsed).unwrap();
        let status = frontend_json.get("status").unwrap();
        assert!(status.get("first_zone_ready").is_none());
        assert!(status.get("watering_targets_ready").is_none());
        assert_eq!(status.get("zone_ready").unwrap(), true);
    }

    #[test]
    fn setup_bootstrap_carries_setup_watering_attempt_to_frontend_json() {
        let parsed: SetupBootstrapResponse = serde_json::from_value(json!({
            "status": {
                "connection_ready": true,
                "first_zone_ready": true,
                "watering_targets_ready": true,
                "zone_ready": true,
                "detected_node_ready": true,
                "assigned_node_ready": true,
                "reading_ready": true,
                "calibration_ready": true,
                "watering_ready": false
            },
            "setup_watering": {
                "state": "in_progress",
                "complete": false,
                "terminal": false,
                "outcome": "in_progress",
                "message": "Watering is still in progress.",
                "idempotency_key": "setup-key-1",
                "target_matches_current": true,
                "event": {
                    "id": 42,
                    "zone_id": "zone1",
                    "node_id": "sensor-zone1-ch0",
                    "command": "start_watering",
                    "status": "running",
                    "reason": "setup_validation",
                    "runtime_seconds": 10,
                    "issued_at": "2026-07-26T12:00:00Z",
                    "idempotency_key": "setup-key-1"
                },
                "target": {
                    "kind": "node",
                    "zone_id": "zone1",
                    "node_id": "sensor-zone1-ch0",
                    "irrigation_line": 1,
                    "crop_profile_id": 7,
                    "runtime_seconds": 10
                }
            },
            "connection_setting": {},
            "crop_profiles": [],
            "first_zone": null,
            "detected_node": null,
            "assigned_node": null
        }))
        .unwrap();

        let frontend_json = serde_json::to_value(parsed).unwrap();
        let setup_watering = frontend_json.get("setup_watering").unwrap();
        assert_eq!(setup_watering.get("state").unwrap(), "in_progress");
        assert_eq!(
            setup_watering.get("idempotency_key").unwrap(),
            "setup-key-1"
        );
        assert_eq!(
            setup_watering
                .get("target")
                .unwrap()
                .get("node_id")
                .unwrap(),
            "sensor-zone1-ch0"
        );
    }

    #[test]
    fn setup_bootstrap_carries_setup_actuator_authority_as_frontend_json() {
        let parsed: SetupBootstrapResponse = serde_json::from_value(json!({
            "status": {
                "connection_ready": true,
                "first_zone_ready": true,
                "watering_targets_ready": true,
                "zone_ready": true,
                "detected_node_ready": true,
                "assigned_node_ready": true,
                "reading_ready": true,
                "calibration_ready": true,
                "watering_ready": false
            },
            "setup_watering": null,
            "setup_actuator": {
                "supported": true,
                "authoritative": true,
                "state": "ready",
                "complete": true,
                "actuator": {
                    "logical_node_id": "actuator-zone1",
                    "provisioning_operation_id": "provision-001"
                },
                "outputs": [
                    { "output_index": 1, "state": "available" }
                ]
            },
            "connection_setting": {},
            "crop_profiles": [],
            "first_zone": null,
            "detected_node": null,
            "assigned_node": null
        }))
        .unwrap();

        let frontend_json = serde_json::to_value(parsed).unwrap();
        let setup_actuator = frontend_json.get("setup_actuator").unwrap();
        assert_eq!(setup_actuator.get("state").unwrap(), "ready");
        assert_eq!(
            setup_actuator
                .get("actuator")
                .unwrap()
                .get("logical_node_id")
                .unwrap(),
            "actuator-zone1"
        );
    }

    #[test]
    fn actuator_provisioning_response_carries_rails_authority_payload() {
        let parsed: SetupActuatorProvisioningResponse = serde_json::from_value(json!({
            "recorded": true,
            "message": "Rails recorded the current actuator provisioning attempt.",
            "status": {
                "connection_ready": true,
                "first_zone_ready": true,
                "watering_targets_ready": true,
                "zone_ready": true,
                "detected_node_ready": true,
                "assigned_node_ready": true,
                "reading_ready": false,
                "calibration_ready": false,
                "watering_ready": false
            },
            "setup_actuator": {
                "supported": true,
                "authoritative": true,
                "state": "pending_observation",
                "complete": false,
                "actuator": {
                    "logical_node_id": "actuator-zone1",
                    "provisioning_operation_id": "provision-001"
                },
                "outputs": []
            }
        }))
        .unwrap();

        let frontend_json = serde_json::to_value(parsed).unwrap();
        assert_eq!(frontend_json.get("recorded").unwrap(), true);
        assert_eq!(
            frontend_json
                .get("setup_actuator")
                .unwrap()
                .get("state")
                .unwrap(),
            "pending_observation"
        );
    }

    #[test]
    fn setup_bootstrap_accepts_null_setup_watering_attempt() {
        let parsed: SetupBootstrapResponse = serde_json::from_value(json!({
            "status": {
                "connection_ready": true,
                "zone_ready": true,
                "detected_node_ready": false,
                "assigned_node_ready": false,
                "reading_ready": false,
                "calibration_ready": false,
                "watering_ready": false
            },
            "setup_watering": null,
            "connection_setting": {},
            "crop_profiles": [],
            "first_zone": null,
            "detected_node": null,
            "assigned_node": null
        }))
        .unwrap();

        assert!(parsed.setup_watering.is_none());
    }

    #[test]
    fn setup_watering_status_carries_terminal_outcome_fields() {
        let parsed: SetupWateringStatusResponse = serde_json::from_value(json!({
            "complete": false,
            "terminal": true,
            "outcome": "faulted",
            "message": "The actuator reported a watering fault.",
            "event": {
                "id": 42,
                "zone_id": "zone1",
                "node_id": "sensor-zone1-ch0",
                "command": "start_watering",
                "status": "fault",
                "reason": "setup_validation",
                "runtime_seconds": 10,
                "issued_at": "2026-07-26T12:00:00Z",
                "idempotency_key": "setup-key-1"
            },
            "actuator_status": null,
            "setup_watering": {
                "state": "recovery",
                "complete": false,
                "terminal": true,
                "outcome": "faulted",
                "message": "The actuator reported a watering fault.",
                "idempotency_key": "setup-key-1",
                "target_matches_current": true,
                "event": null,
                "target": {
                    "kind": "node",
                    "zone_id": "zone1",
                    "node_id": "sensor-zone1-ch0",
                    "irrigation_line": 1,
                    "crop_profile_id": 7,
                    "runtime_seconds": 10
                }
            },
            "zone": null,
            "node": null
        }))
        .unwrap();

        assert!(!parsed.complete);
        assert_eq!(parsed.terminal, Some(true));
        assert_eq!(parsed.outcome.as_deref(), Some("faulted"));
        assert_eq!(
            parsed.message.as_deref(),
            Some("The actuator reported a watering fault.")
        );
        assert_eq!(
            parsed.event.unwrap().idempotency_key,
            "setup-key-1".to_string()
        );
        assert_eq!(
            parsed.setup_watering.unwrap().outcome,
            "faulted".to_string()
        );
    }

    #[test]
    fn setup_watering_status_accepts_legacy_payload_without_terminal_outcome_fields() {
        let parsed: SetupWateringStatusResponse = serde_json::from_value(json!({
            "complete": false,
            "event": null,
            "actuator_status": null,
            "zone": null,
            "node": null
        }))
        .unwrap();

        assert!(!parsed.complete);
        assert_eq!(parsed.terminal, None);
        assert_eq!(parsed.outcome, None);
        assert_eq!(parsed.message, None);
    }

    #[test]
    fn sensor_channel_ids_come_from_the_provisioning_ack() {
        let payload = ProvisionOkPayload {
            node_id: "sensor-zone1".to_string(),
            zone_id: "zone1".to_string(),
            channels: (0..4).map(|channel| format!("sensor-zone1-ch{channel}")).collect(),
            rebooting: true,
        };

        assert_eq!(
            provisioned_channel_ids("sensor", &payload).unwrap(),
            vec![
                "sensor-zone1-ch0",
                "sensor-zone1-ch1",
                "sensor-zone1-ch2",
                "sensor-zone1-ch3"
            ]
        );
    }

    #[test]
    fn sensor_channel_ids_reject_incomplete_acknowledgements() {
        let payload = ProvisionOkPayload {
            node_id: "sensor-zone1".to_string(),
            zone_id: "zone1".to_string(),
            channels: vec!["sensor-zone1-ch0".to_string()],
            rebooting: true,
        };

        assert!(provisioned_channel_ids("sensor", &payload).is_err());
    }
}
