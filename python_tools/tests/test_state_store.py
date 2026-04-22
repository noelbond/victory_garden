import json
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

import pytest

from watering.state import ZoneState
from watering.state_store import (
    get_zone_state,
    load_state_store,
    load_state_store_resilient,
    save_state_store,
)


class TestLoadStateStore:
    def test_load_state_store_valid_file(self):
        state_data = {
            "zone1": {
                "zone_id": "zone1",
                "day": "2026-02-06",
                "runtime_seconds_today": 120,
                "last_watered_at": "2026-02-06T10:30:00Z",
                "last_moisture_percent": 28.5,
            },
            "zone2": {
                "zone_id": "zone2",
                "day": "2026-02-06",
                "runtime_seconds_today": 90,
                "last_watered_at": None,
                "last_moisture_percent": 35.2,
            },
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(state_data, f)
            temp_path = Path(f.name)

        try:
            states = load_state_store(temp_path)
            assert len(states) == 2
            assert "zone1" in states
            assert "zone2" in states
            assert states["zone1"].zone_id == "zone1"
            assert states["zone1"].runtime_seconds_today == 120
            assert states["zone1"].last_moisture_percent == 28.5
            assert states["zone2"].zone_id == "zone2"
            assert states["zone2"].runtime_seconds_today == 90
            assert states["zone2"].last_watered_at is None
        finally:
            temp_path.unlink()

    def test_load_state_store_file_not_found(self):
        non_existent = Path("/tmp/non_existent_state.json")
        states = load_state_store(non_existent)
        assert states == {}

    def test_load_state_store_empty_file(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            f.write("{}")
            temp_path = Path(f.name)

        try:
            states = load_state_store(temp_path)
            assert states == {}
        finally:
            temp_path.unlink()

    def test_load_state_store_empty_json_object(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump({}, f)
            temp_path = Path(f.name)

        try:
            states = load_state_store(temp_path)
            assert states == {}
        finally:
            temp_path.unlink()

    def test_load_state_store_invalid_json(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            f.write("not valid json")
            temp_path = Path(f.name)

        try:
            with pytest.raises(json.JSONDecodeError):
                load_state_store(temp_path)
        finally:
            temp_path.unlink()

    def test_load_state_store_invalid_state_data(self):
        state_data = {
            "zone1": {
                "zone_id": "zone1",
                "day": "2026-02-06",
                "runtime_seconds_today": -100,
            }
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(state_data, f)
            temp_path = Path(f.name)

        try:
            with pytest.raises(Exception):
                load_state_store(temp_path)
        finally:
            temp_path.unlink()

    def test_load_state_store_resilient_quarantines_invalid_json(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            f.write("not valid json")
            temp_path = Path(f.name)

        try:
            states, quarantined_path, error = load_state_store_resilient(temp_path)
            assert states == {}
            assert quarantined_path is not None
            assert quarantined_path.exists()
            assert not temp_path.exists()
            assert error is not None
        finally:
            if temp_path.exists():
                temp_path.unlink()
            if quarantined_path is not None and quarantined_path.exists():
                quarantined_path.unlink()

    def test_load_state_store_resilient_quarantines_invalid_state_data(self):
        state_data = {
            "zone1": {
                "zone_id": "zone1",
                "day": "2026-02-06",
                "runtime_seconds_today": -100,
            }
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(state_data, f)
            temp_path = Path(f.name)

        try:
            states, quarantined_path, error = load_state_store_resilient(temp_path)
            assert states == {}
            assert quarantined_path is not None
            assert quarantined_path.exists()
            assert not temp_path.exists()
            assert error is not None
        finally:
            if temp_path.exists():
                temp_path.unlink()
            if quarantined_path is not None and quarantined_path.exists():
                quarantined_path.unlink()


class TestSaveStateStore:
    def test_save_state_store_single_zone(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        states = {
            "zone1": ZoneState(
                zone_id="zone1",
                day=today,
                runtime_seconds_today=150,
                last_watered_at=now,
                last_moisture_percent=32.1,
            )
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, states)
            assert temp_path.exists()

            with open(temp_path) as f:
                data = json.load(f)

            assert "zone1" in data
            assert data["zone1"]["zone_id"] == "zone1"
            assert data["zone1"]["day"] == "2026-02-06"
            assert data["zone1"]["runtime_seconds_today"] == 150
            assert data["zone1"]["last_moisture_percent"] == 32.1
            assert "2026-02-06T12:00:00" in data["zone1"]["last_watered_at"]
        finally:
            temp_path.unlink()

    def test_save_state_store_multiple_zones(self):
        today = date(2026, 2, 6)
        states = {
            "zone1": ZoneState(
                zone_id="zone1", day=today, runtime_seconds_today=100
            ),
            "zone2": ZoneState(
                zone_id="zone2", day=today, runtime_seconds_today=200
            ),
            "zone3": ZoneState(
                zone_id="zone3", day=today, runtime_seconds_today=0
            ),
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, states)

            with open(temp_path) as f:
                data = json.load(f)

            assert len(data) == 3
            assert "zone1" in data
            assert "zone2" in data
            assert "zone3" in data
            assert data["zone1"]["runtime_seconds_today"] == 100
            assert data["zone2"]["runtime_seconds_today"] == 200
            assert data["zone3"]["runtime_seconds_today"] == 0
        finally:
            temp_path.unlink()

    def test_save_state_store_empty_dict(self):
        states = {}

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, states)

            with open(temp_path) as f:
                data = json.load(f)

            assert data == {}
        finally:
            temp_path.unlink()

    def test_save_state_store_overwrites_existing(self):
        today = date(2026, 2, 6)
        original_states = {
            "zone1": ZoneState(zone_id="zone1", day=today, runtime_seconds_today=50)
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, original_states)

            new_states = {
                "zone2": ZoneState(
                    zone_id="zone2", day=today, runtime_seconds_today=100
                )
            }
            save_state_store(temp_path, new_states)

            with open(temp_path) as f:
                data = json.load(f)

            assert "zone1" not in data
            assert "zone2" in data
            assert data["zone2"]["runtime_seconds_today"] == 100
        finally:
            temp_path.unlink()

    def test_save_state_store_json_formatting(self):
        today = date(2026, 2, 6)
        states = {
            "zone1": ZoneState(zone_id="zone1", day=today, runtime_seconds_today=100)
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, states)

            content = temp_path.read_text()
            assert "\n" in content
            assert "  " in content

            data = json.loads(content)
            assert "zone1" in data
        finally:
            temp_path.unlink()

    def test_save_state_store_sorted_keys(self):
        today = date(2026, 2, 6)
        states = {
            "zone3": ZoneState(zone_id="zone3", day=today, runtime_seconds_today=30),
            "zone1": ZoneState(zone_id="zone1", day=today, runtime_seconds_today=10),
            "zone2": ZoneState(zone_id="zone2", day=today, runtime_seconds_today=20),
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, states)
            content = temp_path.read_text()

            zone1_pos = content.find("zone1")
            zone2_pos = content.find("zone2")
            zone3_pos = content.find("zone3")

            assert zone1_pos < zone2_pos < zone3_pos
        finally:
            temp_path.unlink()


class TestGetZoneState:
    def test_get_zone_state_exists(self):
        today = date(2026, 2, 6)
        states = {
            "zone1": ZoneState(
                zone_id="zone1", day=today, runtime_seconds_today=100
            ),
            "zone2": ZoneState(
                zone_id="zone2", day=today, runtime_seconds_today=200
            ),
        }

        default = ZoneState(zone_id="zone99", day=today, runtime_seconds_today=0)

        result = get_zone_state(states, "zone1", default)
        assert result.zone_id == "zone1"
        assert result.runtime_seconds_today == 100

    def test_get_zone_state_not_exists_returns_default(self):
        today = date(2026, 2, 6)
        states = {
            "zone1": ZoneState(
                zone_id="zone1", day=today, runtime_seconds_today=100
            )
        }

        default = ZoneState(zone_id="zone99", day=today, runtime_seconds_today=0)

        result = get_zone_state(states, "zone2", default)
        assert result.zone_id == "zone99"
        assert result.runtime_seconds_today == 0

    def test_get_zone_state_empty_dict_returns_default(self):
        today = date(2026, 2, 6)
        states = {}
        default = ZoneState(zone_id="zone1", day=today, runtime_seconds_today=0)

        result = get_zone_state(states, "zone1", default)
        assert result == default


class TestRoundTrip:
    def test_save_and_load_roundtrip(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 14, 30, tzinfo=timezone.utc)

        original_states = {
            "zone1": ZoneState(
                zone_id="zone1",
                day=today,
                runtime_seconds_today=120,
                last_watered_at=now,
                last_moisture_percent=28.5,
            ),
            "zone2": ZoneState(
                zone_id="zone2",
                day=today,
                runtime_seconds_today=90,
                last_watered_at=None,
                last_moisture_percent=35.2,
            ),
        }

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            save_state_store(temp_path, original_states)
            loaded_states = load_state_store(temp_path)
            assert len(loaded_states) == 2
            assert loaded_states["zone1"] == original_states["zone1"]
            assert loaded_states["zone2"] == original_states["zone2"]
        finally:
            temp_path.unlink()

    def test_multiple_save_load_cycles(self):
        today = date(2026, 2, 6)

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            temp_path = Path(f.name)

        try:
            states1 = {
                "zone1": ZoneState(
                    zone_id="zone1", day=today, runtime_seconds_today=50
                )
            }
            save_state_store(temp_path, states1)
            loaded1 = load_state_store(temp_path)
            assert loaded1["zone1"].runtime_seconds_today == 50

            states2 = {
                "zone1": ZoneState(
                    zone_id="zone1", day=today, runtime_seconds_today=100
                )
            }
            save_state_store(temp_path, states2)
            loaded2 = load_state_store(temp_path)
            assert loaded2["zone1"].runtime_seconds_today == 100

            states3 = {
                "zone1": ZoneState(
                    zone_id="zone1", day=today, runtime_seconds_today=100
                ),
                "zone2": ZoneState(
                    zone_id="zone2", day=today, runtime_seconds_today=75
                ),
            }
            save_state_store(temp_path, states3)
            loaded3 = load_state_store(temp_path)
            assert len(loaded3) == 2
            assert loaded3["zone2"].runtime_seconds_today == 75
        finally:
            temp_path.unlink()
