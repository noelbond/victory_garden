from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import argparse
import json
import time
from typing import Any

import paho.mqtt.client as mqtt

from watering.config import load_crops, load_zones, validate_zone_crop_refs
from watering.decision import decide_watering
from watering.schemas import SensorReading
from watering.state import ZoneState
from watering.state_store import load_state_store, save_state_store


LATEST_STATE: dict[str, dict[str, Any]] = {}


def on_message(client: mqtt.Client, userdata, msg: mqtt.MQTTMessage) -> None:
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
        zone_id = payload.get("zone_id")
        if zone_id:
            LATEST_STATE[zone_id] = payload
    except Exception as exc:
        print(f"Failed to parse MQTT message on {msg.topic}: {exc}")


def reading_signature(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "zone_id": payload.get("zone_id"),
        "node_id": payload.get("node_id"),
        "wake_count": payload.get("wake_count"),
        "uptime_seconds": payload.get("uptime_seconds"),
        "moisture_raw": payload.get("moisture_raw"),
        "moisture_percent": payload.get("moisture_percent"),
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

    client.publish("greenhouse/run_loop/event", json.dumps(payload))
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

    client.publish("greenhouse/run_loop/skip", json.dumps(payload))
    client.publish(f"greenhouse/zones/{zone_id}/controller/skip_reason", reason)


def publish_request_reading(
    client: mqtt.Client,
    zone_id: str,
    command_id: str,
) -> None:
    payload = {
        "schema_version": "node-command/v1",
        "command": "request_reading",
        "command_id": command_id,
    }
    client.publish(
        f"greenhouse/zones/{zone_id}/command",
        json.dumps(payload),
        retain=True,
    )


def get_zone(zones: Any, zone_id: str | None) -> Any:
    zone_list = list(zones.values()) if isinstance(zones, dict) else list(zones)

    if not zone_list:
        raise ValueError("No zones configured.")

    if zone_id is None:
        return zone_list[0]

    if isinstance(zones, dict):
        if zone_id not in zones:
            raise ValueError(f"Unknown zone_id: {zone_id}")
        return zones[zone_id]

    for zone in zone_list:
        if getattr(zone, "zone_id", None) == zone_id:
            return zone

    raise ValueError(f"Unknown zone_id: {zone_id}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run watering control loop from live MQTT state."
    )
    parser.add_argument("--zone-id", help="Zone to run (defaults to first configured zone).")
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
        help="Cooldown between watering actions in seconds (default: 3 hours).",
    )
    parser.add_argument(
        "--settle-seconds-before-reread",
        type=int,
        default=300,
        help="Delay after watering before requesting a fresh moisture reading.",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]

    crops = load_crops(root / "config" / "crops.yaml")
    zones = load_zones(root / "config" / "zones.yaml")
    validate_zone_crop_refs(crops, zones)

    zone = get_zone(zones, args.zone_id)
    profile = crops[zone.crop_id]

    state_path = root / "state.json"
    states = load_state_store(state_path)

    controller_runtime_path = root / "controller_runtime.json"
    controller_runtime = load_controller_runtime(controller_runtime_path)
    zone_runtime = controller_runtime.get(
        zone.zone_id,
        {
            "last_processed_signature": None,
            "last_watering_signature": None,
            "last_watering_at": None,
            "awaiting_post_watering_reread": False,
            "post_watering_reread_due_at": None,
            "post_watering_reread_requested": False,
        },
    )

    controller = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    controller.connect(args.mqtt_host, args.mqtt_port, 60)
    controller.loop_start()

    subscriber = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    subscriber.on_message = on_message
    subscriber.connect(args.mqtt_host, args.mqtt_port, 60)
    subscriber.subscribe(f"greenhouse/zones/{zone.zone_id}/state")
    subscriber.loop_start()

    try:
        print(f"Waiting for live MQTT state on greenhouse/zones/{zone.zone_id}/state ...")

        while zone.zone_id not in LATEST_STATE:
            time.sleep(args.poll_seconds)

        while True:
            payload = LATEST_STATE.get(zone.zone_id)

            now = datetime.now(timezone.utc)
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
                    controller_runtime[zone.zone_id] = zone_runtime
                    save_controller_runtime(controller_runtime_path, controller_runtime)

            if not payload:
                time.sleep(args.poll_seconds)
                continue

            moisture = float(payload["moisture_percent"])
            signature = reading_signature(payload)

            last_processed_signature = zone_runtime.get("last_processed_signature")
            last_watering_signature = zone_runtime.get("last_watering_signature")
            last_watering_at_raw = zone_runtime.get("last_watering_at")
            awaiting_post_watering_reread = zone_runtime.get(
                "awaiting_post_watering_reread",
                False,
            )

            if signatures_equal(signature, last_processed_signature):
                time.sleep(args.poll_seconds)
                continue

            state = states.get(
                zone.zone_id,
                ZoneState(zone_id=zone.zone_id, day=now.date()),
            )

            if signatures_equal(signature, last_watering_signature):
                print(
                    f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} "
                    "action=skip reason=same-reading-after-watering"
                )
                publish_skip(controller, zone.zone_id, now, "same-reading-after-watering")
                zone_runtime["last_processed_signature"] = signature
                controller_runtime[zone.zone_id] = zone_runtime
                save_controller_runtime(controller_runtime_path, controller_runtime)
                time.sleep(args.poll_seconds)
                continue

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
                    controller_runtime[zone.zone_id] = zone_runtime
                    save_controller_runtime(controller_runtime_path, controller_runtime)
                    time.sleep(args.poll_seconds)
                    continue

            reading = SensorReading(
                node_id=payload["node_id"],
                zone_id=payload["zone_id"],
                moisture_raw=int(payload["moisture_raw"]),
                moisture_percent=moisture,
                soil_temp_c=payload.get("soil_temp_c"),
                battery_percent=payload.get("battery_percent"),
                wifi_rssi=payload.get("wifi_rssi"),
                battery_voltage=payload.get("battery_voltage"),
                uptime_seconds=payload.get("uptime_seconds"),
                wake_count=payload.get("wake_count"),
                ip=payload.get("ip"),
                health=payload.get("health"),
                last_error=payload.get("last_error"),
                publish_reason=payload.get("publish_reason"),
            )

            cmd, state = decide_watering(reading, profile, state, now=now)
            zone_runtime["awaiting_post_watering_reread"] = False
            zone_runtime["post_watering_reread_due_at"] = None
            zone_runtime["post_watering_reread_requested"] = False

            if cmd is None:
                print(f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} action=none")
                publish_event(
                    controller,
                    zone.zone_id,
                    now,
                    moisture,
                    "none",
                    0,
                    state.runtime_seconds_today,
                )
            else:
                print(
                    f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} "
                    f"action=water runtime={cmd.runtime_seconds}s total_today={state.runtime_seconds_today}s"
                )
                publish_event(
                    controller,
                    zone.zone_id,
                    now,
                    moisture,
                    "water",
                    cmd.runtime_seconds,
                    state.runtime_seconds_today,
                )
                zone_runtime["last_watering_signature"] = signature
                zone_runtime["last_watering_at"] = now.isoformat().replace("+00:00", "Z")
                if state.runtime_seconds_today < profile.daily_max_runtime_sec:
                    zone_runtime["awaiting_post_watering_reread"] = True
                    due_at = now.timestamp() + args.settle_seconds_before_reread
                    zone_runtime["post_watering_reread_due_at"] = datetime.fromtimestamp(
                        due_at,
                        tz=timezone.utc,
                    ).isoformat().replace("+00:00", "Z")

            states[zone.zone_id] = state
            save_state_store(state_path, states)

            zone_runtime["last_processed_signature"] = signature
            controller_runtime[zone.zone_id] = zone_runtime
            save_controller_runtime(controller_runtime_path, controller_runtime)

            time.sleep(args.poll_seconds)

    finally:
        subscriber.loop_stop()
        subscriber.disconnect()
        controller.loop_stop()
        controller.disconnect()


if __name__ == "__main__":
    main()
