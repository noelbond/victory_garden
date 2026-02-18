from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import argparse

from watering.config import load_crops, load_zones, validate_zone_crop_refs
from watering.decision import decide_watering
from watering.schemas import SensorReading
from watering.state import ZoneState
from watering.state_store import load_state_store, save_state_store


def _fake_sensor_reading(node_id: str, zone_id: str, moisture: float) -> SensorReading:
    return SensorReading(
        node_id=node_id,
        zone_id=zone_id,
        moisture_raw=1820,
        moisture_percent=moisture,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a simple watering loop.")
    parser.add_argument("--zone-id", help="Zone to run (defaults to first zone).")
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

    now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
    state = states.get(zone.zone_id, ZoneState(zone_id=zone.zone_id, day=now.date()))

    moisture = state.last_moisture_percent or 20.0
    for _ in range(3):
        reading = _fake_sensor_reading(zone.node_id, zone.zone_id, moisture)
        cmd, state = decide_watering(reading, profile, state, now=now)

        if cmd is None:
            print(f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} action=none")
            moisture = max(0.0, moisture - 1.0)
        else:
            print(
                f"{now.isoformat()} zone={zone.zone_id} moisture={moisture:.1f} "
                f"action=water runtime={cmd.runtime_seconds}s total={state.runtime_seconds_today}s"
            )
            moisture = min(100.0, moisture + 8.0)

        now = now + timedelta(minutes=10)

    states[zone.zone_id] = state
    save_state_store(state_path, states)


if __name__ == "__main__":
    main()
