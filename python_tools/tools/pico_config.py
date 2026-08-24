from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any

from serial import Serial
from serial.tools import list_ports


PICO_USB_VID = 0x2E8A


class PicoConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class ReadyConfig:
    port: str
    role: str
    node_id: str
    zone_id: str
    requires_provisioning: bool
    wifi_ssid: str
    mqtt_host: str
    mqtt_port: int


def candidate_ports() -> list[str]:
    ports: dict[str, str] = {}
    for item in list_ports.comports():
        if item.vid != PICO_USB_VID:
            continue
        key = item.device.replace("/dev/tty.", "/dev/cu.")
        ports[key] = key
    return sorted(ports.values())


def reboot_attached_pico() -> None:
    try:
        result = subprocess.run(
            ["picotool", "reboot", "-f"],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except FileNotFoundError as exc:
        raise PicoConfigError("picotool is required but was not found in PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise PicoConfigError("picotool timed out while rebooting the Pico") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise PicoConfigError(f"could not reboot Pico: {detail}")


def wait_for_single_port(timeout: float = 12.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ports = candidate_ports()
        if len(ports) == 1:
            return ports[0]
        if len(ports) > 1:
            raise PicoConfigError(f"multiple Pico serial ports detected: {', '.join(ports)}")
        time.sleep(0.25)
    raise PicoConfigError("timed out waiting for one Pico USB serial port")


def read_ready(port: Serial, timeout: float = 12.0) -> ReadyConfig:
    deadline = time.monotonic() + timeout
    next_identify = 0.0
    while time.monotonic() < deadline:
        if time.monotonic() >= next_identify:
            port.write(b"VG_IDENTIFY\n")
            port.flush()
            next_identify = time.monotonic() + 0.75
        line = port.readline().decode("utf-8", errors="replace").strip()
        if not line.startswith("VG_READY "):
            continue
        try:
            payload = json.loads(line.removeprefix("VG_READY "))
        except json.JSONDecodeError as exc:
            raise PicoConfigError(f"Pico returned invalid VG_READY JSON: {exc}") from exc
        return ReadyConfig(
            port=port.port or "",
            role=str(payload.get("role", "")),
            node_id=str(payload.get("node_id", "")),
            zone_id=str(payload.get("zone_id", "")),
            requires_provisioning=bool(payload.get("requires_provisioning", True)),
            wifi_ssid=str(payload.get("wifi_ssid", "")),
            mqtt_host=str(payload.get("mqtt_host", "")),
            mqtt_port=int(payload.get("mqtt_port", 0)),
        )
    raise PicoConfigError("Pico did not return VG_READY during its configuration review window")


def wait_for_prefix(port: Serial, prefix: str, timeout: float = 12.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = port.readline().decode("utf-8", errors="replace").strip()
        if line.startswith("VG_PROVISION_ERROR "):
            raise PicoConfigError(line.removeprefix("VG_PROVISION_ERROR "))
        if line.startswith(prefix):
            return line
    raise PicoConfigError(f"timed out waiting for {prefix.strip()}")


def try_open_existing_review_session() -> tuple[Serial, ReadyConfig] | None:
    ports = candidate_ports()
    if len(ports) > 1:
        raise PicoConfigError(f"multiple Pico serial ports detected: {', '.join(ports)}")
    if not ports:
        return None
    port = Serial(ports[0], 115200, timeout=0.25)
    try:
        port.reset_input_buffer()
        return port, read_ready(port, timeout=2.0)
    except PicoConfigError:
        port.close()
        return None
    except Exception:
        port.close()
        raise


def open_review_session() -> tuple[Serial, ReadyConfig]:
    existing = try_open_existing_review_session()
    if existing:
        return existing

    reboot_attached_pico()
    port_name = wait_for_single_port()
    port = Serial(port_name, 115200, timeout=0.25)
    try:
        port.reset_input_buffer()
        return port, read_ready(port)
    except Exception:
        port.close()
        raise


def print_ready(ready: ReadyConfig) -> None:
    print(json.dumps({
        "port": ready.port,
        "role": ready.role,
        "node_id": ready.node_id,
        "zone_id": ready.zone_id,
        "requires_provisioning": ready.requires_provisioning,
        "wifi_ssid": ready.wifi_ssid,
        "mqtt_host": ready.mqtt_host,
        "mqtt_port": ready.mqtt_port,
    }, indent=2))


def secret(env_name: str, prompt: str) -> str:
    value = os.environ.get(env_name)
    if value is None:
        value = getpass.getpass(prompt)
    if not value:
        raise PicoConfigError(f"{env_name} cannot be blank")
    return value


def mqtt_hosts_equivalent(saved: str, expected: str) -> bool:
    if saved == expected:
        return True
    try:
        return socket.gethostbyname(saved) == socket.gethostbyname(expected)
    except OSError:
        return False


def update_payload(args: argparse.Namespace, ready: ReadyConfig) -> dict[str, Any]:
    if args.yes and (not args.wifi_ssid or not args.mqtt_host):
        raise PicoConfigError("--yes requires --wifi-ssid and --mqtt-host")
    wifi_ssid = args.wifi_ssid or input(f"Wi-Fi SSID [{ready.wifi_ssid}]: ").strip() or ready.wifi_ssid
    mqtt_host = args.mqtt_host or input(f"MQTT broker [{ready.mqtt_host}]: ").strip() or ready.mqtt_host
    return {
        "wifi_ssid": wifi_ssid,
        "wifi_password": secret("VG_WIFI_PASSWORD", "Wi-Fi password: "),
        "mqtt_host": mqtt_host,
        "mqtt_port": args.mqtt_port,
        "mqtt_username": args.mqtt_username,
        "mqtt_password": secret("VG_MQTT_PASSWORD", "MQTT password: "),
        "node_id": args.node_id or ready.node_id,
        "zone_id": args.zone_id or ready.zone_id,
        "publish_interval_ms": args.publish_interval_ms,
        "utc_offset_hours": args.utc_offset_hours,
    }


def run(args: argparse.Namespace) -> int:
    port, ready = open_review_session()
    try:
        print_ready(ready)
        if args.command == "inspect":
            stale_reasons = []
            if args.expect_wifi_ssid and ready.wifi_ssid != args.expect_wifi_ssid:
                stale_reasons.append(f"Wi-Fi is '{ready.wifi_ssid}', expected '{args.expect_wifi_ssid}'")
            if args.expect_mqtt_host and not mqtt_hosts_equivalent(ready.mqtt_host, args.expect_mqtt_host):
                stale_reasons.append(f"broker is '{ready.mqtt_host}', expected '{args.expect_mqtt_host}'")
            if ready.requires_provisioning:
                stale_reasons.append("configuration is incomplete or contains placeholders")
            if stale_reasons:
                print("STALE: " + "; ".join(stale_reasons), file=sys.stderr)
                return 3
            print("Configuration matches the supplied expectations." if args.expect_wifi_ssid or args.expect_mqtt_host else "Configuration inspected; no expectations were supplied.")
            print("Pico remains in its five-minute USB review window. Run 'vg pico update' or 'vg pico preserve'.")
            return 0

        if args.command == "preserve":
            port.write(b"VG_PRESERVE\n")
            port.flush()
            wait_for_prefix(port, "VG_PRESERVE_OK ")
            print("Saved configuration preserved; Pico is continuing startup.")
            return 0

        payload = update_payload(args, ready)
        if not args.yes:
            answer = input("Replace the Pico configuration with these non-secret values? [y/N] ").strip().lower()
            if answer not in {"y", "yes"}:
                port.write(b"VG_PRESERVE\n")
                port.flush()
                if not ready.requires_provisioning:
                    wait_for_prefix(port, "VG_PRESERVE_OK ")
                print("Update cancelled.")
                return 1
        command = "VG_PROVISION " + json.dumps(payload, separators=(",", ":")) + "\n"
        port.write(command.encode("utf-8"))
        port.flush()
        wait_for_prefix(port, "VG_PROVISION_OK ")
        print("Pico configuration updated; device is rebooting.")
        return 0
    finally:
        port.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect or update retained Victory Garden Pico configuration over USB.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    inspect = subparsers.add_parser("inspect", help="Report non-secret retained configuration, then preserve it and boot.")
    inspect.add_argument("--expect-wifi-ssid", help="Exit 3 when the retained SSID differs.")
    inspect.add_argument("--expect-mqtt-host", help="Exit 3 when the retained broker differs.")
    subparsers.add_parser("preserve", help="Explicitly preserve retained configuration and boot.")
    update = subparsers.add_parser("update", help="Replace retained Wi-Fi/MQTT provisioning over USB.")
    update.add_argument("--wifi-ssid", help="Prompt with the retained SSID as the default when omitted.")
    update.add_argument("--mqtt-host", help="Prompt with the retained broker as the default when omitted.")
    update.add_argument("--mqtt-port", type=int, default=1883)
    update.add_argument("--mqtt-username", default="victory_garden")
    update.add_argument("--node-id")
    update.add_argument("--zone-id")
    update.add_argument("--publish-interval-ms", type=int)
    update.add_argument("--utc-offset-hours", type=int)
    update.add_argument("--yes", action="store_true", help="Skip the final non-secret configuration confirmation.")
    return parser


def main() -> None:
    try:
        raise SystemExit(run(build_parser().parse_args()))
    except PicoConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
