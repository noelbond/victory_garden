from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import argparse
import json

import paho.mqtt.client as mqtt

from watering.config import load_crops, load_zones, validate_zone_crop_refs
from watering.decision import decide_watering
from watering.schemas import SensorReading
from watering.state import ZoneState
from watering.state_store import load_state_store, save_state_store


def publish_event(
    client: mqtt.Client,
    zone_id: str,
    step: int,
    now: datetime,
    moisture: float,
    action: str,
    runtime_seconds: int,
    total_today: int,
) -> None:
    payload = {
        "zone_id": zone_id,
        "step": step,
        "timestamp": now.isoformat(),
        "moisture_percent": moisture,
        "action": action,
        "runtime_seconds": runtime_seconds,
        "runtime_seconds_today": total_today,
    }

    client.publish("greenhouse/simulate/event", json.dumps(payload))
    client.publish(f"greenhouse/zones/{zone_id}/moisture_percent", str(moisture))
    client.publish(f"greenhouse/zones/{zone_id}/action", action)
    client.publish(f"greenhouse/zones/{zone_id}/runtime_seconds_today", str(total_today))
    client.publish(
        f"greenhouse/zones/{zone_id}/state",
        json.dumps(
            {
                "schema_version": "node-state/v1",
                "timestamp": now.isoformat(),
                "zone_id": zone_id,
                "node_id": f"sim-{zone_id}",
                "moisture_raw": 1820,
                "moisture_percent": moisture,
                "soil_temp_c": None,
                "battery_voltage": None,
                "battery_percent": None,
                "wifi_rssi": None,
                "uptime_seconds": None,
                "wake_count": None,
                "ip": None,
                "health": None,
                "last_error": None,
                "publish_reason": "simulated",
            }
        ),
        retain=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Simulate watering decisions.")
    parser.add_argument("--zone-id", help="Zone to simulate (defaults to first zone).")
    parser.add_argument("--mqtt-host", default="127.0.0.1", help="MQTT broker host.")
    parser.add_argument("--mqtt-port", type=int, default=1883, help="MQTT broker port.")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    crops = load_crops(root / "config" / "crops.yaml")
    zones = load_zones(root / "config" / "zones.yaml")
    validate_zone_crop_refs(crops, zones)

    if not zones:
        raise ValueError("No zones configured. Add at least one zone to config/zones.yaml.")

    if args.zone_id:
        if args.zone_id not in zones:
            raise ValueError(f"Unknown zone_id: {args.zone_id}")
        zone = zones[args.zone_id]
    else:
        zone = next(iter(zones.values()))

    profile = crops[zone.crop_id]

    state_path = root / "state.json"
    states = load_state_store(state_path)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.connect(args.mqtt_host, args.mqtt_port, 60)
    client.loop_start()

    try:
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        state = states.get(zone.zone_id, ZoneState(zone_id=zone.zone_id, day=now.date()))

        moisture = state.last_moisture_percent or 20.0
        for step in range(1, 11):
            reading = SensorReading(
                node_id=zone.node_id,
                zone_id=zone.zone_id,
                moisture_raw=1820,
                moisture_percent=moisture,
            )

            cmd, state = decide_watering(reading, profile, state, now=now)

            if cmd is None:
                print(f"Step {step}: moisture={moisture:.1f} -> no watering")
                publish_event(
                    client=client,
                    zone_id=zone.zone_id,
                    step=step,
                    now=now,
                    moisture=moisture,
                    action="none",
                    runtime_seconds=0,
                    total_today=state.runtime_seconds_today,
                )
                moisture = max(0.0, moisture - 1.0)
            else:
                print(
                    f"Step {step}: moisture={moisture:.1f} -> water {cmd.runtime_seconds}s "
                    f"(total today {state.runtime_seconds_today}s)"
                )
                publish_event(
                    client=client,
                    zone_id=zone.zone_id,
                    step=step,
                    now=now,
                    moisture=moisture,
                    action="water",
                    runtime_seconds=cmd.runtime_seconds,
                    total_today=state.runtime_seconds_today,
                )
                moisture = min(100.0, moisture + 8.0)

            now = now + timedelta(minutes=10)

        states[zone.zone_id] = state
        save_state_store(state_path, states)
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
