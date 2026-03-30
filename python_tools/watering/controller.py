from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import argparse
import json
import sys
import time
from typing import Any

import paho.mqtt.client as mqtt

from watering.config import ZoneConfig, load_crops, load_zones, validate_zone_crop_refs
from watering.contracts import NODE_COMMAND_SCHEMA_VERSION
from watering.decision import decide_watering
from watering.profiles import CropProfile
from watering.schemas import SensorReading
from watering.state import ZoneState
from watering.state_store import load_state_store, save_state_store


LATEST_STATE: dict[str, SensorReading] = {}

_ZONE_RUNTIME_DEFAULTS: dict[str, Any] = {
    "last_processed_signature": None,
    "last_watering_signature": None,
    "last_watering_at": None,
    "awaiting_post_watering_reread": False,
    "post_watering_reread_due_at": None,
    "post_watering_reread_requested": False,
}


def parse_sensor_message(topic: str, payload_bytes: bytes) -> SensorReading | None:
    try:
        if not payload_bytes:
            return None
        payload = json.loads(payload_bytes.decode("utf-8"))
        if not isinstance(payload, dict):
            print(f"Failed to parse MQTT message on {topic}: expected JSON object payload")
            return None
        return SensorReading.model_validate(payload)
    except Exception as exc:
        print(f"Failed to parse MQTT message on {topic}: {exc}")
        return None


def on_message(client: mqtt.Client, userdata, msg: mqtt.MQTTMessage) -> None:
    reading = parse_sensor_message(msg.topic, msg.payload)
    if reading is not None:
        LATEST_STATE[reading.zone_id] = reading


def reading_signature(reading: SensorReading) -> dict[str, Any]:
    return {
        "zone_id": reading.zone_id,
        "node_id": reading.node_id,
        "wake_count": reading.wake_count,
        "uptime_seconds": reading.uptime_seconds,
        "moisture_raw": reading.moisture_raw,
        "moisture_percent": reading.moisture_percent,
    }


def signatures_equal(a: dict[str, Any] | None, b: dict[str, Any] | None) -> bool:
    return a == b


def load_controller_runtime(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def save_controller_runtime(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True))


def publish_event(
    client: mqtt.Client,
    zone_id: str,
    now: datetime,
    moisture: float,
    action: str,
    runtime_seconds: int,
    total_today: int,
) -> None:
    payload = {
        "zone_id": zone_id,
        "timestamp": now.isoformat(),
        "moisture_percent": moisture,
        "action": action,
        "runtime_seconds": runtime_seconds,
        "runtime_seconds_today": total_today,
    }
    client.publish(f"greenhouse/zones/{zone_id}/controller/event", json.dumps(payload))
    client.publish(f"greenhouse/zones/{zone_id}/controller/moisture_percent", str(moisture))
    client.publish(f"greenhouse/zones/{zone_id}/controller/action", action)
    client.publish(f"greenhouse/zones/{zone_id}/controller/runtime_seconds_today", str(total_today))


def publish_skip(
    client: mqtt.Client,
    zone_id: str,
    now: datetime,
    reason: str,
) -> None:
    payload = {
        "zone_id": zone_id,
        "timestamp": now.isoformat(),
        "reason": reason,
    }
    client.publish(f"greenhouse/zones/{zone_id}/controller/skip", json.dumps(payload))
    client.publish(f"greenhouse/zones/{zone_id}/controller/skip_reason", reason)


def publish_request_reading(
    client: mqtt.Client,
    zone_id: str,
    command_id: str,
) -> None:
    payload = {
        "schema_version": NODE_COMMAND_SCHEMA_VERSION,
        "command": "request_reading",
        "command_id": command_id,
    }
    client.publish(
        f"greenhouse/zones/{zone_id}/command",
        json.dumps(payload),
        retain=True,
    )


def reading_ready_for_control(reading: SensorReading) -> bool:
    return reading.moisture_percent is not None


def process_zone_tick(
    zone: ZoneConfig,
    profile: CropProfile,
    zone_runtime: dict[str, Any],
    states: dict[str, ZoneState],
    now: datetime,
    args: argparse.Namespace,
    controller: mqtt.Client,
) -> tuple[dict[str, Any], dict[str, ZoneState]]:
    """Run one control-loop tick for a single zone. Returns updated (zone_runtime, states)."""
    reread_due_at_raw = zone_runtime.get("post_watering_reread_due_at")
    reread_requested = zone_runtime.get("post_watering_reread_requested", False)

    if reread_due_at_raw and not reread_requested:
        reread_due_at = datetime.fromisoformat(reread_due_at_raw.replace("Z", "+00:00"))
        if now >= reread_due_at:
            publish_request_reading(
                controller,
                zone.zone_id,
                f"{zone.zone_id}-{reread_due_at:%Y%m%dT%H%M%SZ}-reread",
            )
            zone_runtime["post_watering_reread_requested"] = True

    reading = LATEST_STATE.get(zone.zone_id)

    if reading is None:
        return zone_runtime, states

    if not reading_ready_for_control(reading):
        print(f"{now.isoformat()} zone={zone.zone_id} action=skip reason=incomplete-reading")
        return zone_runtime, states

    moisture = float(reading.moisture_percent)
    signature = reading_signature(reading)

    if signatures_equal(signature, zone_runtime.get("last_processed_signature")):
        return zone_runtime, states

    state = states.get(zone.zone_id, ZoneState(zone_id=zone.zone_id, day=now.date()))

    if signatures_equal(signature, zone_runtime.get("last_watering_signature")):
        print(
            f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} "
            "action=skip reason=same-reading-after-watering"
        )
        publish_skip(controller, zone.zone_id, now, "same-reading-after-watering")
        zone_runtime["last_processed_signature"] = signature
        states[zone.zone_id] = state
        return zone_runtime, states

    last_watering_at_raw = zone_runtime.get("last_watering_at")
    awaiting_post_watering_reread = zone_runtime.get("awaiting_post_watering_reread", False)

    if last_watering_at_raw:
        last_watering_at = datetime.fromisoformat(last_watering_at_raw.replace("Z", "+00:00"))
        seconds_since_watering = (now - last_watering_at).total_seconds()
        if (
            seconds_since_watering < args.min_seconds_between_watering
            and not awaiting_post_watering_reread
        ):
            remaining = int(args.min_seconds_between_watering - seconds_since_watering)
            print(
                f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} "
                f"action=skip reason=cooldown remaining={remaining}s"
            )
            publish_skip(controller, zone.zone_id, now, "cooldown")
            zone_runtime["last_processed_signature"] = signature
            states[zone.zone_id] = state
            return zone_runtime, states

    cmd, state = decide_watering(reading, profile, state, now=now)
    zone_runtime["awaiting_post_watering_reread"] = False
    zone_runtime["post_watering_reread_due_at"] = None
    zone_runtime["post_watering_reread_requested"] = False

    if cmd is None:
        print(f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} action=none")
        publish_event(controller, zone.zone_id, now, moisture, "none", 0, state.runtime_seconds_today)
    else:
        print(
            f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} "
            f"action=water runtime={cmd.runtime_seconds}s total_today={state.runtime_seconds_today}s"
        )
        publish_event(
            controller, zone.zone_id, now, moisture, "water",
            cmd.runtime_seconds, state.runtime_seconds_today,
        )
        zone_runtime["last_watering_signature"] = signature
        zone_runtime["last_watering_at"] = now.isoformat().replace("+00:00", "Z")
        if state.runtime_seconds_today < profile.daily_max_runtime_sec:
            zone_runtime["awaiting_post_watering_reread"] = True
            due_at = now + timedelta(seconds=args.settle_seconds_before_reread)
            zone_runtime["post_watering_reread_due_at"] = due_at.isoformat().replace("+00:00", "Z")

    states[zone.zone_id] = state
    zone_runtime["last_processed_signature"] = signature
    return zone_runtime, states


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run watering control loop from live MQTT state."
    )
    parser.add_argument(
        "--zone-id",
        help="Zone to run (default: all configured zones).",
    )
    parser.add_argument("--mqtt-host", default="127.0.0.1")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=1.0,
        help="How often to check whether a new MQTT reading arrived.",
    )
    parser.add_argument(
        "--min-seconds-between-watering",
        type=int,
        default=10800,
        help="Cooldown between watering actions per zone in seconds (default: 3 hours).",
    )
    parser.add_argument(
        "--settle-seconds-before-reread",
        type=int,
        default=300,
        help="Delay after watering before requesting a fresh moisture reading.",
    )
    parser.add_argument(
        "--startup-timeout-seconds",
        type=int,
        default=120,
        help="Seconds to wait for the first MQTT reading before giving up (default: 120).",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]

    crops = load_crops(root / "config" / "crops.yaml")
    all_zones = load_zones(root / "config" / "zones.yaml")
    validate_zone_crop_refs(crops, all_zones)

    if args.zone_id:
        if args.zone_id not in all_zones:
            print(
                f"ERROR: Unknown zone_id '{args.zone_id}'. "
                f"Configured zones: {', '.join(all_zones)}",
                flush=True,
            )
            sys.exit(1)
        active_zones: dict[str, ZoneConfig] = {args.zone_id: all_zones[args.zone_id]}
    else:
        active_zones = dict(all_zones)

    state_path = root / "state.json"
    states = load_state_store(state_path)

    controller_runtime_path = root / "controller_runtime.json"
    controller_runtime = load_controller_runtime(controller_runtime_path)

    for zone_id in active_zones:
        controller_runtime.setdefault(zone_id, dict(_ZONE_RUNTIME_DEFAULTS))

    controller = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    controller.connect(args.mqtt_host, args.mqtt_port, 60)
    controller.loop_start()

    subscriber = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    subscriber.on_message = on_message
    subscriber.connect(args.mqtt_host, args.mqtt_port, 60)
    for zone_id in active_zones:
        subscriber.subscribe(f"greenhouse/zones/{zone_id}/state")
    subscriber.loop_start()

    zone_list = ", ".join(active_zones)
    print(f"Waiting for live MQTT state for zone(s): {zone_list} ...")

    try:
        startup_deadline = time.monotonic() + args.startup_timeout_seconds
        while not any(zid in LATEST_STATE for zid in active_zones):
            if time.monotonic() > startup_deadline:
                print(
                    f"ERROR: No MQTT reading for any of [{zone_list}] within "
                    f"{args.startup_timeout_seconds}s. Check broker connection and topics.",
                    flush=True,
                )
                sys.exit(1)
            time.sleep(args.poll_seconds)

        while True:
            now = datetime.now(timezone.utc)

            for zone_id, zone in active_zones.items():
                profile = crops[zone.crop_id]
                zone_runtime = controller_runtime.setdefault(zone_id, dict(_ZONE_RUNTIME_DEFAULTS))

                updated_runtime, states = process_zone_tick(
                    zone, profile, zone_runtime, states, now, args, controller
                )
                controller_runtime[zone_id] = updated_runtime

            save_state_store(state_path, states)
            save_controller_runtime(controller_runtime_path, controller_runtime)

            time.sleep(args.poll_seconds)

    finally:
        subscriber.loop_stop()
        subscriber.disconnect()
        controller.loop_stop()
        controller.disconnect()


if __name__ == "__main__":
    main()
