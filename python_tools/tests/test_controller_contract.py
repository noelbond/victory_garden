import json
from datetime import date, datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from watering.controller import (
    LATEST_STATE,
    on_message,
    parse_sensor_message,
    reading_ready_for_control,
)
from watering.decision import decide_watering
from watering.profiles import CropProfile
from watering.schemas import HubCommand
from watering.state import ZoneState


FIXTURES_DIR = Path(__file__).resolve().parents[2] / "contracts" / "examples"


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURES_DIR / name).read_text())


class TestControllerContract:
    def setup_method(self):
        LATEST_STATE.clear()

    def test_real_node_payload_flows_through_controller(self):
        payload = load_fixture("node-state-v1.json")
        message = SimpleNamespace(
            topic=f"greenhouse/zones/{payload['zone_id']}/state",
            payload=json.dumps(payload).encode("utf-8"),
        )

        on_message(None, None, message)

        reading = LATEST_STATE["zone1"]
        assert reading.schema_version == "node-state/v1"
        assert reading.node_id == "mkr1010-zone1"

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )
        state = ZoneState(zone_id="zone1", day=date(2026, 3, 18))

        command, new_state = decide_watering(
            reading,
            profile,
            state,
            now=datetime(2026, 3, 18, 23, 13, 56, tzinfo=timezone.utc),
        )

        assert command is not None
        assert command.command == HubCommand.START_WATER
        assert command.runtime_seconds == 45
        assert new_state.runtime_seconds_today == 45

    def test_retained_empty_payload_is_ignored(self):
        assert parse_sensor_message("greenhouse/zones/zone1/state", b"") is None

    def test_legacy_payload_alias_is_accepted(self):
        payload = load_fixture("node-state-legacy-rssi.json")
        reading = parse_sensor_message(
            "greenhouse/zones/zone1/state",
            json.dumps(payload).encode("utf-8"),
        )

        assert reading is not None
        assert reading.wifi_rssi == -61
        assert reading.zone_id == "zone1"

    def test_partial_payload_is_not_ready_for_control(self):
        payload = load_fixture("node-state-partial.json")
        reading = parse_sensor_message(
            "greenhouse/zones/zone1/state",
            json.dumps(payload).encode("utf-8"),
        )

        assert reading is not None
        assert reading.moisture_percent is None
        assert reading_ready_for_control(reading) is False

    def test_optional_metadata_payload_is_accepted(self):
        payload = load_fixture("node-state-optional-nulls.json")
        reading = parse_sensor_message(
            "greenhouse/zones/zone1/state",
            json.dumps(payload).encode("utf-8"),
        )

        assert reading is not None
        assert reading.schema_version == "node-state/v1"
        assert reading.battery_voltage is None
        assert reading.health is None
