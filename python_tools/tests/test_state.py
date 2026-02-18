from datetime import date, datetime, timezone

import pytest
from pydantic import ValidationError

from watering.state import ZoneState


class TestZoneState:
    def test_valid_zone_state(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        state = ZoneState(
            zone_id="zone1",
            day=today,
            runtime_seconds_today=120,
            last_watered_at=now,
            last_moisture_percent=31.4,
        )
        assert state.zone_id == "zone1"
        assert state.day == today
        assert state.runtime_seconds_today == 120
        assert state.last_watered_at == now
        assert state.last_moisture_percent == 31.4

    def test_zone_state_minimal(self):
        today = date(2026, 2, 6)
        state = ZoneState(zone_id="zone1", day=today)
        assert state.zone_id == "zone1"
        assert state.day == today
        assert state.runtime_seconds_today == 0
        assert state.last_watered_at is None
        assert state.last_moisture_percent is None

    def test_zone_state_empty_zone_id_fails(self):
        with pytest.raises(ValidationError) as exc:
            ZoneState(zone_id="", day=date(2026, 2, 6))
        assert "zone_id" in str(exc.value)

    def test_zone_state_runtime_out_of_range(self):
        today = date(2026, 2, 6)
        with pytest.raises(ValidationError):
            ZoneState(zone_id="z1", day=today, runtime_seconds_today=-1)
        with pytest.raises(ValidationError):
            ZoneState(zone_id="z1", day=today, runtime_seconds_today=86_401)

    def test_zone_state_moisture_percent_out_of_range(self):
        today = date(2026, 2, 6)
        with pytest.raises(ValidationError):
            ZoneState(zone_id="z1", day=today, last_moisture_percent=-0.1)
        with pytest.raises(ValidationError):
            ZoneState(zone_id="z1", day=today, last_moisture_percent=100.1)

    def test_zone_state_extra_field_forbidden(self):
        today = date(2026, 2, 6)
        with pytest.raises(ValidationError) as exc:
            ZoneState(
                zone_id="z1",
                day=today,
                extra_field="not_allowed",
            )
        assert "extra_field" in str(exc.value).lower()

    def test_zone_state_boundary_values_runtime(self):
        today = date(2026, 2, 6)
        state = ZoneState(zone_id="z1", day=today, runtime_seconds_today=0)
        assert state.runtime_seconds_today == 0

        state = ZoneState(zone_id="z1", day=today, runtime_seconds_today=86_400)
        assert state.runtime_seconds_today == 86_400

    def test_zone_state_boundary_values_moisture(self):
        today = date(2026, 2, 6)
        state = ZoneState(zone_id="z1", day=today, last_moisture_percent=0.0)
        assert state.last_moisture_percent == 0.0

        state = ZoneState(zone_id="z1", day=today, last_moisture_percent=100.0)
        assert state.last_moisture_percent == 100.0

    def test_zone_state_model_copy(self):
        today = date(2026, 2, 6)
        state1 = ZoneState(zone_id="z1", day=today, runtime_seconds_today=60)
        state2 = state1.model_copy(update={"runtime_seconds_today": 120})

        assert state1.runtime_seconds_today == 60
        assert state2.runtime_seconds_today == 120
        assert state1.zone_id == state2.zone_id
        assert state1.day == state2.day

    def test_zone_state_model_copy_deep(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        state1 = ZoneState(
            zone_id="z1",
            day=today,
            runtime_seconds_today=60,
            last_watered_at=now,
        )
        state2 = state1.model_copy(deep=True)

        # Should be equal but different instances
        assert state1 == state2
        assert state1 is not state2

    def test_zone_state_serialization(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        state = ZoneState(
            zone_id="zone1",
            day=today,
            runtime_seconds_today=150,
            last_watered_at=now,
            last_moisture_percent=28.7,
        )
        data = state.model_dump()
        assert data["zone_id"] == "zone1"
        assert data["day"] == today
        assert data["runtime_seconds_today"] == 150
        assert data["last_watered_at"] == now
        assert data["last_moisture_percent"] == 28.7

    def test_zone_state_serialization_mode_json(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        state = ZoneState(
            zone_id="zone1",
            day=today,
            runtime_seconds_today=150,
            last_watered_at=now,
            last_moisture_percent=28.7,
        )
        data = state.model_dump(mode="json")
        # Dates/datetimes should be serialized as ISO strings
        assert isinstance(data["day"], str)
        assert data["day"] == "2026-02-06"
        assert isinstance(data["last_watered_at"], str)

    def test_zone_state_deserialization(self):
        data = {
            "zone_id": "zone2",
            "day": "2026-02-06",
            "runtime_seconds_today": 180,
            "last_watered_at": "2026-02-06T14:30:00Z",
            "last_moisture_percent": 35.2,
        }
        state = ZoneState.model_validate(data)
        assert state.zone_id == "zone2"
        assert state.day == date(2026, 2, 6)
        assert state.runtime_seconds_today == 180
        assert state.last_watered_at == datetime(2026, 2, 6, 14, 30, tzinfo=timezone.utc)
        assert state.last_moisture_percent == 35.2

    def test_zone_state_deserialization_minimal(self):
        data = {
            "zone_id": "zone3",
            "day": "2026-02-06",
        }
        state = ZoneState.model_validate(data)
        assert state.zone_id == "zone3"
        assert state.day == date(2026, 2, 6)
        assert state.runtime_seconds_today == 0
        assert state.last_watered_at is None
        assert state.last_moisture_percent is None

    def test_zone_state_equality(self):
        today = date(2026, 2, 6)
        state1 = ZoneState(zone_id="z1", day=today, runtime_seconds_today=100)
        state2 = ZoneState(zone_id="z1", day=today, runtime_seconds_today=100)
        state3 = ZoneState(zone_id="z1", day=today, runtime_seconds_today=200)

        assert state1 == state2
        assert state1 != state3

    def test_zone_state_day_change_scenario(self):
        # Test scenario where day changes (common use case)
        yesterday = date(2026, 2, 5)
        today = date(2026, 2, 6)

        state_yesterday = ZoneState(
            zone_id="z1",
            day=yesterday,
            runtime_seconds_today=300,
            last_moisture_percent=32.0,
        )

        # When day changes, runtime should reset
        state_today = state_yesterday.model_copy(
            update={"day": today, "runtime_seconds_today": 0}
        )

        assert state_today.day == today
        assert state_today.runtime_seconds_today == 0
        assert state_today.last_moisture_percent == 32.0  # Preserved

    def test_zone_state_incremental_runtime_update(self):
        # Test scenario of adding runtime after watering
        today = date(2026, 2, 6)
        state = ZoneState(zone_id="z1", day=today, runtime_seconds_today=0)

        # First watering
        state = state.model_copy(update={"runtime_seconds_today": 45})
        assert state.runtime_seconds_today == 45

        # Second watering
        state = state.model_copy(update={"runtime_seconds_today": 45 + 45})
        assert state.runtime_seconds_today == 90

        # Third watering
        state = state.model_copy(update={"runtime_seconds_today": 90 + 45})
        assert state.runtime_seconds_today == 135
