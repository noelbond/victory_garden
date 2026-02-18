"""Pytest configuration and shared fixtures for the watering system tests."""

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
    """Fixture providing today's date."""
    return date(2026, 2, 6)


@pytest.fixture
def now():
    """Fixture providing current datetime."""
    return datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)


@pytest.fixture
def tomato_profile():
    """Fixture providing a tomato crop profile."""
    return CropProfile(
        crop_id="tomato",
        crop_name="Tomato",
        dry_threshold=30.0,
        runtime_seconds=45,
        max_daily_runtime_seconds=300,
    )


@pytest.fixture
def basil_profile():
    """Fixture providing a basil crop profile."""
    return CropProfile(
        crop_id="basil",
        crop_name="Basil",
        dry_threshold=35.0,
        runtime_seconds=30,
        max_daily_runtime_seconds=240,
    )


@pytest.fixture
def zone_state(today):
    """Fixture providing a fresh zone state."""
    return ZoneState(zone_id="zone1", day=today)


@pytest.fixture
def dry_reading():
    """Fixture providing a sensor reading indicating dry soil."""
    return SensorReading(
        node_id="sensor-1",
        zone_id="zone1",
        moisture_raw=2600,
        moisture_percent=25.0,
    )


@pytest.fixture
def wet_reading():
    """Fixture providing a sensor reading indicating wet soil."""
    return SensorReading(
        node_id="sensor-1",
        zone_id="zone1",
        moisture_raw=2000,
        moisture_percent=40.0,
    )


@pytest.fixture
def calibration_profile():
    """Fixture providing a typical calibration profile."""
    return CalibrationProfile(raw_dry=3000, raw_wet=1200)


@pytest.fixture
def temp_json_file():
    """Fixture providing a temporary JSON file path."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        temp_path = Path(f.name)
    yield temp_path
    # Cleanup
    if temp_path.exists():
        temp_path.unlink()


@pytest.fixture
def temp_yaml_file():
    """Fixture providing a temporary YAML file path."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        temp_path = Path(f.name)
    yield temp_path
    # Cleanup
    if temp_path.exists():
        temp_path.unlink()


@pytest.fixture
def sample_crops_yaml():
    """Fixture providing sample crops YAML content."""
    return """crops:
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


@pytest.fixture
def sample_zones_yaml():
    """Fixture providing sample zones YAML content."""
    return """zones:
  - zone_id: zone1
    crop_id: tomato
    node_id: sensor-gh1-zone1
  - zone_id: zone2
    crop_id: basil
    node_id: sensor-gh1-zone2
"""
