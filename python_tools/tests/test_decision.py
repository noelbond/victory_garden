from datetime import datetime, timezone, date

from watering.decision import decide_watering
from watering.profiles import CropProfile
from watering.schemas import HubCommand, SensorReading
from watering.state import ZoneState


class TestBasicDecisions:
    def test_decide_watering_issues_command_and_updates_state(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone3", day=now.date())

        reading = SensorReading(
            node_id="sensor-gh1-zone3",
            zone_id="zone3",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert cmd.command == HubCommand.START_WATER
        assert cmd.zone_id == "zone3"
        assert cmd.runtime_seconds == 45
        assert cmd.reason == "below_dry_threshold"
        assert new_state.runtime_seconds_today == 45
        assert new_state.last_watered_at == now
        assert new_state.last_moisture_percent == 25.0

    def test_decide_watering_no_command_if_not_dry(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="basil",
            crop_name="Basil",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone3", day=now.date())

        reading = SensorReading(
            node_id="sensor-gh1-zone3",
            zone_id="zone3",
            moisture_raw=1820,
            moisture_percent=45.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None
        assert new_state.runtime_seconds_today == 0
        assert new_state.last_moisture_percent == 45.0

    def test_decide_watering_exactly_at_threshold_no_command(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=30.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None
        assert new_state.runtime_seconds_today == 0

    def test_decide_watering_just_below_threshold_waters(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=29.9,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert cmd.runtime_seconds == 45


class TestDailyCapLogic:
    def test_decide_watering_respects_daily_cap_exact(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date(), runtime_seconds_today=300)

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None
        assert new_state.runtime_seconds_today == 300

    def test_decide_watering_respects_daily_cap_exceeded(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        # Already exceeded the daily cap (shouldn't happen in normal operation)
        state = ZoneState(zone_id="zone1", day=now.date(), runtime_seconds_today=350)

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None
        assert new_state.runtime_seconds_today == 350

    def test_decide_watering_caps_runtime_to_remaining_daily(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date(), runtime_seconds_today=280)

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert cmd.runtime_seconds == 20
        assert new_state.runtime_seconds_today == 300

    def test_decide_watering_one_second_remaining(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date(), runtime_seconds_today=299)

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert cmd.runtime_seconds == 1
        assert new_state.runtime_seconds_today == 300


class TestDayRollover:
    def test_decide_watering_resets_on_new_day(self):
        yesterday = date(2026, 2, 5)
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 8, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=yesterday, runtime_seconds_today=300)

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert cmd.runtime_seconds == 45
        assert new_state.day == today
        assert new_state.runtime_seconds_today == 45

    def test_decide_watering_preserves_same_day(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=today, runtime_seconds_today=100)

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert new_state.day == today
        assert new_state.runtime_seconds_today == 145


class TestNullMoistureHandling:
    def test_decide_watering_null_moisture_no_command(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=None,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None
        assert new_state.runtime_seconds_today == 0
        assert new_state.last_moisture_percent is None


class TestMultipleWateringsPerDay:
    def test_decide_watering_multiple_waterings_same_day(self):
        now = datetime(2026, 2, 6, 8, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date(), runtime_seconds_today=0)

        reading1 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=25.0
        )
        cmd1, state = decide_watering(reading1, profile, state, now=now)
        assert cmd1 is not None
        assert cmd1.runtime_seconds == 45
        assert state.runtime_seconds_today == 45

        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)
        reading2 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=26.0
        )
        cmd2, state = decide_watering(reading2, profile, state, now=now)
        assert cmd2 is not None
        assert cmd2.runtime_seconds == 45
        assert state.runtime_seconds_today == 90

        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        reading3 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=27.0
        )
        cmd3, state = decide_watering(reading3, profile, state, now=now)
        assert cmd3 is not None
        assert state.runtime_seconds_today == 135

        state = state.model_copy(update={"runtime_seconds_today": 280})
        reading4 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=28.0
        )
        cmd4, state = decide_watering(reading4, profile, state, now=now)
        assert cmd4 is not None
        assert cmd4.runtime_seconds == 20
        assert state.runtime_seconds_today == 300


class TestIdempotencyKeys:
    def test_decide_watering_unique_idempotency_keys(self):
        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=date(2026, 2, 6))

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=25.0,
        )

        now1 = datetime(2026, 2, 6, 10, 0, 0, tzinfo=timezone.utc)
        cmd1, _ = decide_watering(reading, profile, state, now=now1)

        now2 = datetime(2026, 2, 6, 10, 0, 1, tzinfo=timezone.utc)
        cmd2, _ = decide_watering(reading, profile, state, now=now2)

        assert cmd1.idempotency_key != cmd2.idempotency_key
        assert "zone1" in cmd1.idempotency_key
        assert "zone1" in cmd2.idempotency_key


class TestStateUpdates:
    def test_decide_watering_updates_last_moisture_always(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=25.0
        )
        _, new_state = decide_watering(reading, profile, state, now=now)
        assert new_state.last_moisture_percent == 25.0

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2000, moisture_percent=45.0
        )
        _, new_state = decide_watering(reading, profile, state, now=now)
        assert new_state.last_moisture_percent == 45.0

    def test_decide_watering_updates_last_watered_at_only_when_watering(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=25.0
        )
        _, new_state = decide_watering(reading, profile, state, now=now)
        assert new_state.last_watered_at == now

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2000, moisture_percent=45.0
        )
        _, new_state = decide_watering(reading, profile, state, now=now)
        assert new_state.last_watered_at is None


class TestEdgeCases:
    def test_decide_watering_zero_runtime_profile(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=0,
            max_daily_runtime_seconds=100,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=25.0
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None

    def test_decide_watering_zero_max_daily_runtime(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=0,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=25.0
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is None

    def test_decide_watering_extreme_dry_threshold(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=100.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=99.9
        )

        cmd, _ = decide_watering(reading, profile, state, now=now)
        assert cmd is not None

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=100.0
        )

        cmd, _ = decide_watering(reading, profile, state, now=now)
        assert cmd is None

    def test_decide_watering_extreme_dry_threshold_zero(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="test",
            crop_name="Test",
            dry_threshold=0.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=now.date())

        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=1820, moisture_percent=0.0
        )

        cmd, _ = decide_watering(reading, profile, state, now=now)
        assert cmd is None
