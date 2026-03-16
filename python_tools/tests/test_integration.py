import json
import tempfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

from watering.calibration import CalibrationProfile, raw_to_percent
from watering.config import load_crops, load_zones
from watering.decision import decide_watering
from watering.profiles import CropProfile
from watering.schemas import HubCommand, SensorReading
from watering.state import ZoneState
from watering.state_store import get_zone_state, load_state_store, save_state_store


class TestEndToEndWateringWorkflow:
    def test_single_watering_cycle(self):
        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)

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
            moisture_raw=2550,
            moisture_percent=25.0,
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert cmd.command == HubCommand.START_WATER
        assert cmd.runtime_seconds == 45

        assert new_state.runtime_seconds_today == 45
        assert new_state.last_watered_at == now
        assert new_state.last_moisture_percent == 25.0

    def test_multiple_readings_same_day(self):
        today = date(2026, 2, 6)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=today)

        now1 = datetime(2026, 2, 6, 8, 0, tzinfo=timezone.utc)
        reading1 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )
        cmd1, state = decide_watering(reading1, profile, state, now=now1)
        assert cmd1 is not None
        assert state.runtime_seconds_today == 45

        now2 = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)
        reading2 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2500, moisture_percent=27.0
        )
        cmd2, state = decide_watering(reading2, profile, state, now=now2)
        assert cmd2 is not None
        assert state.runtime_seconds_today == 90

        now3 = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        reading3 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2000, moisture_percent=35.0
        )
        cmd3, state = decide_watering(reading3, profile, state, now=now3)
        assert cmd3 is None
        assert state.runtime_seconds_today == 90

    def test_day_rollover_workflow(self):
        yesterday = date(2026, 2, 5)
        today = date(2026, 2, 6)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=yesterday, runtime_seconds_today=300)

        now = datetime(2026, 2, 6, 8, 0, tzinfo=timezone.utc)
        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert new_state.day == today
        assert new_state.runtime_seconds_today == 45

    def test_state_persistence_workflow(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            state_file = Path(f.name)

        try:
            states = {"zone1": ZoneState(zone_id="zone1", day=today)}
            reading1 = SensorReading(
                node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
            )
            cmd1, states["zone1"] = decide_watering(
                reading1, profile, states["zone1"], now=now
            )
            assert cmd1 is not None
            save_state_store(state_file, states)

            loaded_states = load_state_store(state_file)
            now2 = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
            reading2 = SensorReading(
                node_id="sensor-1", zone_id="zone1", moisture_raw=2500, moisture_percent=26.0
            )
            state2 = get_zone_state(
                loaded_states, "zone1", ZoneState(zone_id="zone1", day=today)
            )
            cmd2, state2 = decide_watering(reading2, profile, state2, now=now2)

            assert cmd2 is not None
            assert state2.runtime_seconds_today == 90
        finally:
            state_file.unlink()


class TestMultiZoneWorkflow:
    def test_two_zones_independent_state(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)

        tomato_profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        basil_profile = CropProfile(
            crop_id="basil",
            crop_name="Basil",
            dry_threshold=35.0,
            runtime_seconds=30,
            max_daily_runtime_seconds=240,
        )

        states = {
            "zone1": ZoneState(zone_id="zone1", day=today),
            "zone2": ZoneState(zone_id="zone2", day=today),
        }

        reading1 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )
        cmd1, states["zone1"] = decide_watering(
            reading1, tomato_profile, states["zone1"], now=now
        )
        assert cmd1 is not None
        assert states["zone1"].runtime_seconds_today == 45

        reading2 = SensorReading(
            node_id="sensor-2", zone_id="zone2", moisture_raw=2000, moisture_percent=40.0
        )
        cmd2, states["zone2"] = decide_watering(
            reading2, basil_profile, states["zone2"], now=now
        )
        assert cmd2 is None
        assert states["zone2"].runtime_seconds_today == 0

        assert states["zone1"].runtime_seconds_today != states["zone2"].runtime_seconds_today

    def test_multi_zone_state_persistence(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            state_file = Path(f.name)

        try:
            states = {
                "zone1": ZoneState(zone_id="zone1", day=today, runtime_seconds_today=45),
                "zone2": ZoneState(zone_id="zone2", day=today, runtime_seconds_today=30),
                "zone3": ZoneState(zone_id="zone3", day=today, runtime_seconds_today=0),
            }

            save_state_store(state_file, states)
            loaded = load_state_store(state_file)
            assert len(loaded) == 3
            assert loaded["zone1"].runtime_seconds_today == 45
            assert loaded["zone2"].runtime_seconds_today == 30
            assert loaded["zone3"].runtime_seconds_today == 0
        finally:
            state_file.unlink()


class TestConfigIntegration:
    def test_load_and_use_crop_config(self):
        yaml_content = """crops:
  - crop_id: tomato
    crop_name: Tomato
    dry_threshold: 30.0
    runtime_seconds: 45
    max_daily_runtime_seconds: 300
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            config_file = Path(f.name)

        try:
            crops = load_crops(config_file)
            tomato = crops["tomato"]

            today = date(2026, 2, 6)
            now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)
            state = ZoneState(zone_id="zone1", day=today)
            reading = SensorReading(
                node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
            )

            cmd, new_state = decide_watering(reading, tomato, state, now=now)

            assert cmd is not None
            assert cmd.runtime_seconds == 45
        finally:
            config_file.unlink()

    def test_load_and_use_zone_config(self):
        crops_yaml = """crops:
  - crop_id: tomato
    crop_name: Tomato
    dry_threshold: 30.0
    runtime_seconds: 45
    max_daily_runtime_seconds: 300
  - crop_id: basil
    crop_name: Basil
    dry_threshold: 35.0
    runtime_seconds: 30
    max_daily_runtime_seconds: 240
"""
        zones_yaml = """zones:
  - zone_id: zone1
    crop_id: tomato
    node_id: sensor-gh1-zone1
  - zone_id: zone2
    crop_id: basil
    node_id: sensor-gh1-zone2
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(crops_yaml)
            crops_file = Path(f.name)

        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(zones_yaml)
            zones_file = Path(f.name)

        try:
            crops = load_crops(crops_file)
            zones = load_zones(zones_file)

            assert zones["zone1"].crop_id == "tomato"
            assert zones["zone2"].crop_id == "basil"

            zone1_crop = crops[zones["zone1"].crop_id]
            assert zone1_crop.crop_name == "Tomato"
            assert zone1_crop.runtime_seconds == 45
        finally:
            crops_file.unlink()
            zones_file.unlink()


class TestCalibrationIntegration:
    def test_calibrate_and_decide(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)

        cal_profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)

        crop_profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=today)

        raw_value = 2550

        moisture_percent = raw_to_percent(raw_value, cal_profile)
        assert 20 <= moisture_percent <= 30

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=raw_value,
            moisture_percent=moisture_percent,
        )

        cmd, new_state = decide_watering(reading, crop_profile, state, now=now)

        assert cmd is not None

    def test_calibration_prevents_watering_when_wet(self):
        today = date(2026, 2, 6)
        now = datetime(2026, 2, 6, 10, 0, tzinfo=timezone.utc)

        cal_profile = CalibrationProfile(raw_dry=3000, raw_wet=1200)
        crop_profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=today)

        raw_value = 1500
        moisture_percent = raw_to_percent(raw_value, cal_profile)
        assert moisture_percent > 30

        reading = SensorReading(
            node_id="sensor-1",
            zone_id="zone1",
            moisture_raw=raw_value,
            moisture_percent=moisture_percent,
        )

        cmd, new_state = decide_watering(reading, crop_profile, state, now=now)

        assert cmd is None


class TestDailyLimitEnforcement:
    def test_daily_limit_across_multiple_waterings(self):
        today = date(2026, 2, 6)
        base_time = datetime(2026, 2, 6, 8, 0, tzinfo=timezone.utc)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=100,
            max_daily_runtime_seconds=250,
        )

        state = ZoneState(zone_id="zone1", day=today)

        reading1 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )
        cmd1, state = decide_watering(reading1, profile, state, now=base_time)
        assert cmd1 is not None
        assert cmd1.runtime_seconds == 100
        assert state.runtime_seconds_today == 100

        reading2 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )
        cmd2, state = decide_watering(
            reading2, profile, state, now=base_time + timedelta(hours=2)
        )
        assert cmd2 is not None
        assert cmd2.runtime_seconds == 100
        assert state.runtime_seconds_today == 200

        reading3 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )
        cmd3, state = decide_watering(
            reading3, profile, state, now=base_time + timedelta(hours=4)
        )
        assert cmd3 is not None
        assert cmd3.runtime_seconds == 50
        assert state.runtime_seconds_today == 250

        reading4 = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )
        cmd4, state = decide_watering(
            reading4, profile, state, now=base_time + timedelta(hours=6)
        )
        assert cmd4 is None
        assert state.runtime_seconds_today == 250

    def test_daily_limit_resets_on_new_day(self):
        yesterday = date(2026, 2, 5)
        today = date(2026, 2, 6)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=yesterday, runtime_seconds_today=300)

        now = datetime(2026, 2, 6, 8, 0, tzinfo=timezone.utc)
        reading = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2600, moisture_percent=25.0
        )

        cmd, new_state = decide_watering(reading, profile, state, now=now)

        assert cmd is not None
        assert new_state.day == today
        assert new_state.runtime_seconds_today == 45


class TestRealWorldScenario:
    def test_typical_day_cycle(self):
        today = date(2026, 2, 6)

        profile = CropProfile(
            crop_id="tomato",
            crop_name="Tomato",
            dry_threshold=30.0,
            runtime_seconds=45,
            max_daily_runtime_seconds=300,
        )

        state = ZoneState(zone_id="zone1", day=today)

        morning = datetime(2026, 2, 6, 6, 0, tzinfo=timezone.utc)
        reading_morning = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2700, moisture_percent=22.0
        )
        cmd_morning, state = decide_watering(reading_morning, profile, state, now=morning)
        assert cmd_morning is not None
        assert state.runtime_seconds_today == 45

        afternoon = datetime(2026, 2, 6, 14, 0, tzinfo=timezone.utc)
        reading_afternoon = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2400, moisture_percent=28.0
        )
        cmd_afternoon, state = decide_watering(
            reading_afternoon, profile, state, now=afternoon
        )
        assert cmd_afternoon is not None
        assert state.runtime_seconds_today == 90

        evening = datetime(2026, 2, 6, 18, 0, tzinfo=timezone.utc)
        reading_evening = SensorReading(
            node_id="sensor-1", zone_id="zone1", moisture_raw=2000, moisture_percent=38.0
        )
        cmd_evening, state = decide_watering(reading_evening, profile, state, now=evening)
        assert cmd_evening is None
        assert state.runtime_seconds_today == 90
