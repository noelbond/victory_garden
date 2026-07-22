#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import paho.mqtt.client as mqtt


ZONE_ID = "e2e-zone"
DEVICE_ID = "e2e-sensor-pico"
NODE_IDS = [f"{DEVICE_ID}-ch{i}" for i in range(4)]
SYSTEM_CONFIG_TOPIC = "greenhouse/system/config/current"
ACTUATOR_CONFIG_TOPIC = "greenhouse/system/actuator/config/current"
PYTHON_STATE_FILES = ["state.json", "controller_runtime.json", "controller_health.json"]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def json_dumps(payload: dict[str, Any]) -> str:
    return json.dumps(payload, separators=(",", ":"))


@dataclass
class MqttEvent:
    topic: str
    payload: dict[str, Any] | str | None
    retained: bool
    received_at: str = field(default_factory=utc_now_iso)


class EventCollector:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.events: list[MqttEvent] = []
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        if args.mqtt_username:
            self.client.username_pw_set(args.mqtt_username, args.mqtt_password or None)
        self.client.on_message = self._on_message

    def _on_message(self, _client: mqtt.Client, _userdata: Any, msg: mqtt.MQTTMessage) -> None:
        payload_text = msg.payload.decode("utf-8", errors="replace") if msg.payload else ""
        payload: dict[str, Any] | str | None
        if payload_text:
            try:
                parsed = json.loads(payload_text)
                payload = parsed if isinstance(parsed, dict) else payload_text
            except json.JSONDecodeError:
                payload = payload_text
        else:
            payload = None
        self.events.append(MqttEvent(msg.topic, payload, bool(msg.retain)))

    def start(self) -> None:
        self.client.connect(self.args.mqtt_host, self.args.mqtt_port, 60)
        self.client.subscribe(f"greenhouse/zones/{ZONE_ID}/#")
        self.client.subscribe(SYSTEM_CONFIG_TOPIC)
        self.client.subscribe(ACTUATOR_CONFIG_TOPIC)
        self.client.loop_start()

    def stop(self) -> None:
        self.client.loop_stop()
        self.client.disconnect()

    def publish(self, topic: str, payload: dict[str, Any] | str | None, retain: bool = False) -> None:
        if payload is None:
            message = ""
        elif isinstance(payload, str):
            message = payload
        else:
            message = json_dumps(payload)
        info = self.client.publish(topic, message, qos=0, retain=retain)
        info.wait_for_publish(timeout=5)

    def since(self, start_index: int) -> list[MqttEvent]:
        return self.events[start_index:]


def wait_for(
    collector: EventCollector,
    start_index: int,
    predicate,
    description: str,
    timeout: float,
) -> MqttEvent:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for event in collector.since(start_index):
            if predicate(event):
                print(f"[e2e] observed {description}: {event.topic} {event.payload}", flush=True)
                return event
        time.sleep(0.1)
    raise TimeoutError(f"Timed out waiting for {description}")


def assert_no_event(
    collector: EventCollector,
    start_index: int,
    predicate,
    description: str,
    duration: float,
) -> None:
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        for event in collector.since(start_index):
            if predicate(event):
                raise AssertionError(f"Unexpected {description}: {event.topic} {event.payload}")
        time.sleep(0.1)
    print(f"[e2e] confirmed no {description} for {duration:.1f}s", flush=True)


def payload_has(event: MqttEvent, **fields: Any) -> bool:
    if not isinstance(event.payload, dict):
        return False
    return all(event.payload.get(key) == value for key, value in fields.items())


def event_topic(kind: str) -> str:
    return f"greenhouse/zones/{ZONE_ID}/{kind}"


def node_state_topic(node_id: str) -> str:
    return f"greenhouse/zones/{ZONE_ID}/nodes/{node_id}/state"


def build_system_config(runtime_seconds: int, daily_max_seconds: int, dry_threshold: float) -> dict[str, Any]:
    crop = {
        "crop_id": "e2e-fast",
        "crop_name": "E2E Fast Crop",
        "dry_threshold": dry_threshold,
        "max_pulse_runtime_sec": runtime_seconds,
        "daily_max_runtime_sec": daily_max_seconds,
        "climate_preference": "test",
        "time_to_harvest_days": None,
    }
    return {
        "crops": [crop],
        "zones": [
            {
                "zone_id": ZONE_ID,
                "crop_id": crop["crop_id"],
                "node_ids": NODE_IDS,
                "active": True,
                "allowed_hours": None,
                "irrigation_line": None,
                "watering_mode": "node",
            }
        ],
        "nodes": [
            {
                "node_id": node_id,
                "zone_id": ZONE_ID,
                "crop_id": crop["crop_id"],
                "active": True,
                "allowed_hours": None,
                "irrigation_line": index + 1,
            }
            for index, node_id in enumerate(NODE_IDS)
        ],
        "watering_mode": "node",
    }


def build_actuator_config(line_count: int = 4) -> dict[str, Any]:
    return {
        "schema_version": "actuator-config/v1",
        "config_version": f"e2e-{utc_now().strftime('%Y%m%dT%H%M%SZ')}",
        "irrigation_line_count": line_count,
        "zones": [],
        "nodes": [
            {
                "node_id": node_id,
                "zone_id": ZONE_ID,
                "irrigation_line": index + 1,
                "active": True,
            }
            for index, node_id in enumerate(NODE_IDS)
        ],
    }


def sensor_payload(node_id: str, moisture: float | None, wake_count: int, timestamp: str | None = None) -> dict[str, Any]:
    return {
        "schema_version": "node-state/v1",
        "timestamp": timestamp or utc_now_iso(),
        "zone_id": ZONE_ID,
        "node_id": node_id,
        "device_id": DEVICE_ID,
        "moisture_raw": 19000 if moisture is not None else 0,
        "moisture_percent": moisture,
        "soil_moisture_read": moisture is not None,
        "air_temperature_c": 21.5,
        "humidity_percent": 58.0,
        "greenhouse_alert_status": "normal",
        "soil_temp_c": None,
        "battery_voltage": None,
        "battery_percent": None,
        "wifi_rssi": -55,
        "uptime_seconds": 1000 + wake_count,
        "wake_count": wake_count,
        "ip": "synthetic",
        "health": "ok",
        "last_error": "none",
        "publish_reason": "e2e_test",
    }


def actuator_status_predicate(node_id: str, state: str):
    return lambda event: event.topic == event_topic("actuator/status") and payload_has(event, node_id=node_id, state=state)


def actuator_fault_predicate(fault_code: str):
    return (
        lambda event:
            event.topic == event_topic("actuator/status")
            and isinstance(event.payload, dict)
            and event.payload.get("state") == "FAULT"
            and event.payload.get("fault_code") == fault_code
    )


def controller_event_predicate(node_id: str, action: str):
    return lambda event: event.topic == event_topic("controller/event") and payload_has(event, node_id=node_id, action=action)


def controller_skip_predicate(node_id: str, reason: str):
    return lambda event: event.topic == event_topic("controller/skip") and payload_has(event, node_id=node_id, reason=reason)


def command_predicate(node_id: str):
    return (
        lambda event:
            event.topic == event_topic("actuator/command")
            and isinstance(event.payload, dict)
            and event.payload.get("command") == "start_watering"
            and event.payload.get("node_id") == node_id
    )


def backup_python_state(root: Path) -> dict[Path, str | None]:
    backup: dict[Path, str | None] = {}
    for name in PYTHON_STATE_FILES:
        path = root / name
        backup[path] = path.read_text() if path.exists() else None
        if path.exists():
            path.unlink()
    return backup


def restore_python_state(backup: dict[Path, str | None]) -> None:
    for path, text in backup.items():
        if text is None:
            if path.exists():
                path.unlink()
        else:
            path.write_text(text)


def start_controller(args: argparse.Namespace, python_root: Path) -> subprocess.Popen:
    command = [
        sys.executable,
        "-m",
        "main",
        "--mqtt-host",
        args.mqtt_host,
        "--mqtt-port",
        str(args.mqtt_port),
        "--poll-seconds",
        str(args.controller_poll_seconds),
        "--min-seconds-between-watering",
        str(args.cooldown_seconds),
        "--max-reading-age-seconds",
        str(args.max_reading_age_seconds),
        "--startup-timeout-seconds",
        "8",
    ]
    if args.mqtt_username:
        command.extend(["--mqtt-username", args.mqtt_username])
    if args.mqtt_password:
        command.extend(["--mqtt-password", args.mqtt_password])

    print(f"[e2e] starting controller: {' '.join(command)}", flush=True)
    return subprocess.Popen(
        command,
        cwd=python_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ, "PYTHONUNBUFFERED": "1"},
    )


def stop_controller(process: subprocess.Popen | None) -> str:
    if process is None:
        return ""
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
    output = ""
    if process.stdout is not None:
        output = process.stdout.read()
    return output


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True))


def run(args: argparse.Namespace) -> int:
    python_root = Path(__file__).resolve().parents[1]
    output_path = Path(args.output).expanduser().resolve()
    controller_process: subprocess.Popen | None = None
    controller_output = ""
    state_backup = backup_python_state(python_root)
    collector = EventCollector(args)
    previous_payloads: dict[str, dict[str, Any] | str | None] = {}
    checks: list[dict[str, Any]] = []

    try:
        collector.start()
        time.sleep(1.0)
        for topic in (SYSTEM_CONFIG_TOPIC, ACTUATOR_CONFIG_TOPIC):
            retained = next((event for event in reversed(collector.events) if event.topic == topic and event.retained), None)
            previous_payloads[topic] = retained.payload if retained else None

        for node_id in NODE_IDS:
            collector.publish(node_state_topic(node_id), None, retain=True)
        collector.publish(event_topic("actuator/command"), None, retain=True)

        collector.publish(SYSTEM_CONFIG_TOPIC, build_system_config(args.runtime_seconds, args.daily_max_seconds, args.dry_threshold), retain=True)
        collector.publish(ACTUATOR_CONFIG_TOPIC, build_actuator_config(), retain=True)
        time.sleep(args.actuator_config_settle_seconds)

        controller_process = start_controller(args, python_root)

        print("[e2e] scenario 1: wet reading should not water", flush=True)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[0]), sensor_payload(NODE_IDS[0], 72.0, 1), retain=True)
        wait_for(collector, mark, controller_event_predicate(NODE_IDS[0], "none"), "wet/no-water controller event", 8)
        assert_no_event(collector, mark, command_predicate(NODE_IDS[0]), "watering command for wet node", 2)
        checks.append({"scenario": "wet_no_water", "status": "passed"})

        print("[e2e] scenario 2: dry ch0 should water line 1 and complete", flush=True)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[0]), sensor_payload(NODE_IDS[0], 8.0, 2), retain=True)
        wait_for(collector, mark, command_predicate(NODE_IDS[0]), "ch0 watering command", 8)
        wait_for(collector, mark, actuator_status_predicate(NODE_IDS[0], "RUNNING"), "ch0 actuator RUNNING", 8)
        wait_for(collector, mark, actuator_status_predicate(NODE_IDS[0], "COMPLETED"), "ch0 actuator COMPLETED", args.runtime_seconds + 8)
        checks.append({"scenario": "dry_ch0_waters", "status": "passed"})

        print("[e2e] scenario 3: immediate ch0 reread should cooldown-skip", flush=True)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[0]), sensor_payload(NODE_IDS[0], 7.0, 3), retain=True)
        wait_for(collector, mark, controller_skip_predicate(NODE_IDS[0], "cooldown"), "ch0 cooldown skip", 8)
        assert_no_event(collector, mark, command_predicate(NODE_IDS[0]), "watering command during cooldown", 2)
        checks.append({"scenario": "cooldown_skip", "status": "passed"})

        print("[e2e] scenario 4: ch1 and ch2 dry together should run independent lines", flush=True)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[1]), sensor_payload(NODE_IDS[1], 9.0, 4), retain=True)
        collector.publish(node_state_topic(NODE_IDS[2]), sensor_payload(NODE_IDS[2], 11.0, 5), retain=True)
        for node_id in (NODE_IDS[1], NODE_IDS[2]):
            wait_for(collector, mark, command_predicate(node_id), f"{node_id} watering command", 8)
            wait_for(collector, mark, actuator_status_predicate(node_id, "RUNNING"), f"{node_id} actuator RUNNING", 8)
            wait_for(collector, mark, actuator_status_predicate(node_id, "COMPLETED"), f"{node_id} actuator COMPLETED", args.runtime_seconds + 8)
        checks.append({"scenario": "parallel_node_watering", "status": "passed"})

        print("[e2e] scenario 5: stale and incomplete readings should skip", flush=True)
        stale_timestamp = (utc_now() - timedelta(seconds=args.max_reading_age_seconds + 5)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[3]), sensor_payload(NODE_IDS[3], 5.0, 6, timestamp=stale_timestamp), retain=True)
        wait_for(collector, mark, controller_skip_predicate(NODE_IDS[3], "stale_reading"), "ch3 stale skip", 8)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[3]), sensor_payload(NODE_IDS[3], None, 7), retain=True)
        wait_for(collector, mark, controller_skip_predicate(NODE_IDS[3], "incomplete-reading"), "ch3 incomplete skip", 8)
        checks.append({"scenario": "stale_and_incomplete_skip", "status": "passed"})

        print("[e2e] scenario 6: ch1 should stop watering after daily cap", flush=True)
        time.sleep(args.cooldown_seconds + 0.5)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[1]), sensor_payload(NODE_IDS[1], 6.0, 8), retain=True)
        wait_for(collector, mark, command_predicate(NODE_IDS[1]), "ch1 second watering command", 8)
        wait_for(collector, mark, actuator_status_predicate(NODE_IDS[1], "COMPLETED"), "ch1 second actuator COMPLETED", args.runtime_seconds + 8)
        time.sleep(args.cooldown_seconds + 0.5)
        mark = len(collector.events)
        collector.publish(node_state_topic(NODE_IDS[1]), sensor_payload(NODE_IDS[1], 5.0, 9), retain=True)
        wait_for(collector, mark, controller_event_predicate(NODE_IDS[1], "none"), "ch1 daily cap no-water event", 8)
        assert_no_event(collector, mark, command_predicate(NODE_IDS[1]), "watering command after daily cap", 2)
        checks.append({"scenario": "daily_runtime_cap", "status": "passed"})

        print("[e2e] scenario 7: actuator should fault unknown node target", flush=True)
        mark = len(collector.events)
        collector.publish(
            event_topic("actuator/command"),
            {
                "command": "start_watering",
                "zone_id": ZONE_ID,
                "node_id": "e2e-missing-node",
                "runtime_seconds": args.runtime_seconds,
                "reason": "e2e_unknown_node",
                "idempotency_key": f"e2e-missing-{utc_now().strftime('%Y%m%dT%H%M%SZ')}",
            },
            retain=False,
        )
        wait_for(collector, mark, actuator_fault_predicate("UNASSIGNED_LINE"), "unknown-node actuator fault", 8)
        checks.append({"scenario": "unknown_node_fault", "status": "passed"})

        report = {
            "status": "passed",
            "started_at": collector.events[0].received_at if collector.events else utc_now_iso(),
            "finished_at": utc_now_iso(),
            "zone_id": ZONE_ID,
            "node_ids": NODE_IDS,
            "checks": checks,
            "event_count": len(collector.events),
            "events": [event.__dict__ for event in collector.events],
        }
        write_report(output_path, report)
        print(f"[e2e] passed; report={output_path}", flush=True)
        return 0
    except Exception as exc:
        checks.append({"scenario": "run", "status": "failed", "error": str(exc)})
        report = {
            "status": "failed",
            "finished_at": utc_now_iso(),
            "zone_id": ZONE_ID,
            "node_ids": NODE_IDS,
            "checks": checks,
            "event_count": len(collector.events),
            "events": [event.__dict__ for event in collector.events],
            "error": str(exc),
        }
        write_report(output_path, report)
        print(f"[e2e] failed: {exc}; report={output_path}", flush=True)
        return 1
    finally:
        controller_output = stop_controller(controller_process)
        if controller_output:
            controller_log_path = output_path.with_suffix(".controller.log")
            controller_log_path.write_text(controller_output)
            print(f"[e2e] controller log={controller_log_path}", flush=True)
        if args.restore_retained:
            for node_id in NODE_IDS:
                collector.publish(node_state_topic(node_id), None, retain=True)
            collector.publish(event_topic("actuator/command"), None, retain=True)
            for topic, payload in previous_payloads.items():
                collector.publish(topic, payload, retain=True)
            print("[e2e] restored previous retained system config and cleared e2e retained states", flush=True)
        restore_python_state(state_backup)
        collector.stop()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run an accelerated live MQTT/Pico end-to-end watering test.")
    parser.add_argument("--mqtt-host", default="192.168.4.36")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--mqtt-username", default=os.environ.get("MQTT_USERNAME", "victory_garden"))
    parser.add_argument("--mqtt-password", default=os.environ.get("MQTT_PASSWORD"))
    parser.add_argument("--runtime-seconds", type=int, default=2)
    parser.add_argument("--daily-max-seconds", type=int, default=4)
    parser.add_argument("--cooldown-seconds", type=int, default=3)
    parser.add_argument("--dry-threshold", type=float, default=30.0)
    parser.add_argument("--max-reading-age-seconds", type=int, default=10)
    parser.add_argument("--controller-poll-seconds", type=float, default=0.5)
    parser.add_argument("--actuator-config-settle-seconds", type=float, default=3.0)
    parser.add_argument("--no-restore-retained", dest="restore_retained", action="store_false")
    parser.set_defaults(restore_retained=True)
    parser.add_argument("--output", default="python_tools/logs/e2e_accelerated_hardware_test.json")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.runtime_seconds <= 0:
        parser.error("--runtime-seconds must be positive")
    if args.daily_max_seconds < args.runtime_seconds:
        parser.error("--daily-max-seconds must be >= --runtime-seconds")
    if args.cooldown_seconds < 0:
        parser.error("--cooldown-seconds cannot be negative")
    if args.max_reading_age_seconds <= 0:
        parser.error("--max-reading-age-seconds must be positive")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
