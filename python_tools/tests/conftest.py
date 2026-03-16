import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

import pytest

from watering.calibration import CalibrationProfile
from watering.profiles import CropProfile
from watering.schemas import SensorReading
from watering.state import ZoneState


@pytest.fixture
def today():
    return date(2026, 2, 6)


@pytest.fixture
def now():
    return datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)


@pytest.fixture
def tomato_profile():
    return CropProfile(
        crop_id="tomato",
        crop_name="Tomato",
        dry_threshold=30.0,
        max_pulse_runtime_sec=45,
        daily_max_runtime_sec=300,
        climate_preference="Warm, sunny",
        time_to_harvest_days=75,
    )


@pytest.fixture
def basil_profile():
    return CropProfile(
        crop_id="basil",
        crop_name="Basil",
        dry_threshold=40.0,
        max_pulse_runtime_sec=30,
        daily_max_runtime_sec=240,
        climate_preference="Warm, humid",
        time_to_harvest_days=50,
    )


@pytest.fixture
def zone_state(today):
    return ZoneState(zone_id="zone1", day=today)


@pytest.fixture
def dry_reading():
    return SensorReading(
        node_id="sensor-1",
        zone_id="zone1",
        moisture_raw=2600,
        moisture_percent=25.0,
    )


@pytest.fixture
def wet_reading():
    return SensorReading(
        node_id="sensor-1",
        zone_id="zone1",
        moisture_raw=2000,
        moisture_percent=40.0,
    )


@pytest.fixture
def calibration_profile():
    return CalibrationProfile(raw_dry=3000, raw_wet=1200)


@pytest.fixture
def temp_json_file():
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        temp_path = Path(f.name)
    yield temp_path
    if temp_path.exists():
        temp_path.unlink()


@pytest.fixture
def temp_yaml_file():
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        temp_path = Path(f.name)
    yield temp_path
    if temp_path.exists():
        temp_path.unlink()


@pytest.fixture
def sample_crops_yaml():
    return """crops:
  - crop_id: tomato
    crop_name: Tomato
    dry_threshold: 30.0
    max_pulse_runtime_sec: 45
    daily_max_runtime_sec: 300
    climate_preference: Warm, sunny
    time_to_harvest_days: 75
  - crop_id: basil
    crop_name: Basil
    dry_threshold: 40.0
    max_pulse_runtime_sec: 30
    daily_max_runtime_sec: 240
    climate_preference: Warm, humid
    time_to_harvest_days: 50
"""


@pytest.fixture
def sample_zones_yaml():
    return """zones:
  - zone_id: zone1
    crop_id: tomato
    node_id: sensor-gh1-zone1
  - zone_id: zone2
    crop_id: basil
    node_id: sensor-gh1-zone2
"""
