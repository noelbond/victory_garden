import tempfile
from pathlib import Path

import pytest
from pydantic import ValidationError

from watering.config import (
    CropsConfig,
    ZoneConfig,
    ZonesConfig,
    load_crops,
    load_zones,
    validate_zone_crop_refs,
)
from watering.profiles import CropProfile


class TestCropsConfig:
    def test_valid_crops_config(self):
        data = {
            "crops": [
                {
                    "crop_id": "tomato",
                    "crop_name": "Tomato",
                    "dry_threshold": 30.0,
                    "max_pulse_runtime_sec": 45,
                    "daily_max_runtime_sec": 300,
                    "climate_preference": "Warm, sunny",
                    "time_to_harvest_days": 75,
                },
                {
                    "crop_id": "basil",
                    "crop_name": "Basil",
                    "dry_threshold": 40.0,
                    "max_pulse_runtime_sec": 30,
                    "daily_max_runtime_sec": 240,
                    "climate_preference": "Warm, humid",
                    "time_to_harvest_days": 50,
                },
            ]
        }
        config = CropsConfig.model_validate(data)
        assert len(config.crops) == 2
        assert config.crops[0].crop_id == "tomato"
        assert config.crops[1].crop_id == "basil"

    def test_crops_config_empty_list(self):
        data = {"crops": []}
        config = CropsConfig.model_validate(data)
        assert len(config.crops) == 0

    def test_crops_config_extra_field_forbidden(self):
        data = {"crops": [], "extra_field": "not_allowed"}
        with pytest.raises(ValidationError) as exc:
            CropsConfig.model_validate(data)
        assert "extra_field" in str(exc.value).lower()

    def test_crops_config_invalid_crop_fails(self):
        data = {
            "crops": [
                {
                    "crop_id": "",
                    "crop_name": "Tomato",
                    "dry_threshold": 30.0,
                    "max_pulse_runtime_sec": 45,
                    "daily_max_runtime_sec": 300,
                }
            ]
        }
        with pytest.raises(ValidationError):
            CropsConfig.model_validate(data)


class TestZoneConfig:
    def test_valid_zone_config(self):
        data = {
            "zone_id": "zone1",
            "crop_id": "tomato",
            "node_id": "sensor-gh1-zone1",
        }
        zone = ZoneConfig.model_validate(data)
        assert zone.zone_id == "zone1"
        assert zone.crop_id == "tomato"
        assert zone.node_id == "sensor-gh1-zone1"

    def test_zone_config_empty_zone_id_fails(self):
        data = {"zone_id": "", "crop_id": "tomato", "node_id": "sensor-1"}
        with pytest.raises(ValidationError):
            ZoneConfig.model_validate(data)

    def test_zone_config_empty_crop_id_fails(self):
        data = {"zone_id": "zone1", "crop_id": "", "node_id": "sensor-1"}
        with pytest.raises(ValidationError):
            ZoneConfig.model_validate(data)

    def test_zone_config_empty_node_id_fails(self):
        data = {"zone_id": "zone1", "crop_id": "tomato", "node_id": ""}
        with pytest.raises(ValidationError):
            ZoneConfig.model_validate(data)

    def test_zone_config_extra_field_forbidden(self):
        data = {
            "zone_id": "zone1",
            "crop_id": "tomato",
            "node_id": "sensor-1",
            "extra_field": "not_allowed",
        }
        with pytest.raises(ValidationError):
            ZoneConfig.model_validate(data)


class TestZonesConfig:
    def test_valid_zones_config(self):
        data = {
            "zones": [
                {"zone_id": "zone1", "crop_id": "tomato", "node_id": "sensor-gh1-zone1"},
                {"zone_id": "zone2", "crop_id": "basil", "node_id": "sensor-gh1-zone2"},
            ]
        }
        config = ZonesConfig.model_validate(data)
        assert len(config.zones) == 2
        assert config.zones[0].zone_id == "zone1"
        assert config.zones[1].zone_id == "zone2"

    def test_zones_config_empty_list(self):
        data = {"zones": []}
        config = ZonesConfig.model_validate(data)
        assert len(config.zones) == 0

    def test_zones_config_extra_field_forbidden(self):
        data = {"zones": [], "extra_field": "not_allowed"}
        with pytest.raises(ValidationError):
            ZonesConfig.model_validate(data)


class TestLoadCrops:
    def test_load_crops_valid_file(self):
        yaml_content = """crops:
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
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            crops = load_crops(temp_path)
            assert len(crops) == 2
            assert "tomato" in crops
            assert "basil" in crops
            assert crops["tomato"].crop_name == "Tomato"
            assert crops["tomato"].dry_threshold == 30.0
            assert crops["basil"].crop_name == "Basil"
            assert crops["basil"].max_pulse_runtime_sec == 30
        finally:
            temp_path.unlink()

    def test_load_crops_file_not_found(self):
        non_existent = Path("/tmp/non_existent_crops.yaml")
        with pytest.raises(FileNotFoundError) as exc:
            load_crops(non_existent)
        assert "Config file not found" in str(exc.value)

    def test_load_crops_empty_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("")
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValidationError):
                load_crops(temp_path)
        finally:
            temp_path.unlink()

    def test_load_crops_invalid_yaml(self):
        yaml_content = """crops:
  - crop_id: tomato
    crop_name: Tomato
    dry_threshold: invalid_number
    max_pulse_runtime_sec: 45
    daily_max_runtime_sec: 300
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValidationError):
                load_crops(temp_path)
        finally:
            temp_path.unlink()

    def test_load_crops_missing_required_field(self):
        yaml_content = """crops:
  - crop_id: tomato
    crop_name: Tomato
    max_pulse_runtime_sec: 45
    daily_max_runtime_sec: 300
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValidationError):
                load_crops(temp_path)
        finally:
            temp_path.unlink()

    def test_load_crops_duplicate_crop_ids(self):
        yaml_content = """crops:
  - crop_id: tomato
    crop_name: Tomato A
    dry_threshold: 30.0
    max_pulse_runtime_sec: 45
    daily_max_runtime_sec: 300
  - crop_id: tomato
    crop_name: Tomato B
    dry_threshold: 35.0
    max_pulse_runtime_sec: 50
    daily_max_runtime_sec: 350
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValueError) as exc:
                load_crops(temp_path)
            assert "duplicate crop_id" in str(exc.value).lower()
        finally:
            temp_path.unlink()


class TestLoadZones:
    def test_load_zones_valid_file(self):
        yaml_content = """zones:
  - zone_id: zone1
    crop_id: tomato
    node_id: sensor-gh1-zone1
  - zone_id: zone2
    crop_id: basil
    node_id: sensor-gh1-zone2
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            zones = load_zones(temp_path)
            assert len(zones) == 2
            assert "zone1" in zones
            assert "zone2" in zones
            assert zones["zone1"].crop_id == "tomato"
            assert zones["zone1"].node_id == "sensor-gh1-zone1"
            assert zones["zone2"].crop_id == "basil"
        finally:
            temp_path.unlink()

    def test_load_zones_file_not_found(self):
        non_existent = Path("/tmp/non_existent_zones.yaml")
        with pytest.raises(FileNotFoundError) as exc:
            load_zones(non_existent)
        assert "Config file not found" in str(exc.value)

    def test_load_zones_empty_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("")
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValidationError):
                load_zones(temp_path)
        finally:
            temp_path.unlink()

    def test_load_zones_invalid_yaml(self):
        yaml_content = """zones:
  - zone_id: zone1
    crop_id: ""
    node_id: sensor-1
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValidationError):
                load_zones(temp_path)
        finally:
            temp_path.unlink()

    def test_load_zones_missing_required_field(self):
        yaml_content = """zones:
  - zone_id: zone1
    node_id: sensor-1
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValidationError):
                load_zones(temp_path)
        finally:
            temp_path.unlink()

    def test_load_zones_duplicate_zone_ids(self):
        yaml_content = """zones:
  - zone_id: zone1
    crop_id: tomato
    node_id: sensor-1
  - zone_id: zone1
    crop_id: basil
    node_id: sensor-2
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            with pytest.raises(ValueError) as exc:
                load_zones(temp_path)
            assert "duplicate zone_id" in str(exc.value).lower()
        finally:
            temp_path.unlink()

    def test_load_zones_with_comment(self):
        yaml_content = """# Zone configuration
zones:
  - zone_id: zone1
    crop_id: tomato
    node_id: sensor-gh1-zone1  # Main greenhouse
"""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write(yaml_content)
            temp_path = Path(f.name)

        try:
            zones = load_zones(temp_path)
            assert len(zones) == 1
            assert zones["zone1"].crop_id == "tomato"
        finally:
            temp_path.unlink()


class TestValidateZoneCropRefs:
    def test_validate_zone_crop_refs_passes(self):
        crops = {
            "tomato": CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
            )
        }
        zones = {
            "zone1": ZoneConfig(
                zone_id="zone1",
                crop_id="tomato",
                node_id="sensor-gh1-zone1",
            )
        }
        validate_zone_crop_refs(crops, zones)

    def test_validate_zone_crop_refs_missing_crop(self):
        crops = {
            "tomato": CropProfile(
                crop_id="tomato",
                crop_name="Tomato",
                dry_threshold=30.0,
                runtime_seconds=45,
                max_daily_runtime_seconds=300,
            )
        }
        zones = {
            "zone1": ZoneConfig(
                zone_id="zone1",
                crop_id="basil",
                node_id="sensor-gh1-zone1",
            )
        }
        with pytest.raises(ValueError) as exc:
            validate_zone_crop_refs(crops, zones)
        assert "unknown crop_id" in str(exc.value).lower()
