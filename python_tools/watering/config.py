from __future__ import annotations

from pathlib import Path
from typing import Dict, List

import yaml
from pydantic import BaseModel, ConfigDict, Field

from watering.profiles import CropProfile


class CropsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    crops: List[CropProfile]


class ZoneConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    zone_id: str = Field(min_length=1, examples=["zone1"])
    crop_id: str = Field(min_length=1, examples=["tomato"])
    node_id: str = Field(min_length=1, examples=["sensor-gh1-zone1"])


class ZonesConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")
    zones: List[ZoneConfig]


def _load_yaml(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(f"Config file not found: {path}")
    return yaml.safe_load(path.read_text()) or {}


def load_crops(path: Path) -> Dict[str, CropProfile]:
    raw = _load_yaml(path)
    config = CropsConfig.model_validate(raw)
    crop_ids = [crop.crop_id for crop in config.crops]
    if len(crop_ids) != len(set(crop_ids)):
        raise ValueError("Duplicate crop_id found in crops config.")
    return {crop.crop_id: crop for crop in config.crops}


def load_zones(path: Path) -> Dict[str, ZoneConfig]:
    raw = _load_yaml(path)
    config = ZonesConfig.model_validate(raw)
    zone_ids = [zone.zone_id for zone in config.zones]
    if len(zone_ids) != len(set(zone_ids)):
        raise ValueError("Duplicate zone_id found in zones config.")
    return {zone.zone_id: zone for zone in config.zones}


def validate_zone_crop_refs(
    crops: Dict[str, CropProfile],
    zones: Dict[str, ZoneConfig],
) -> None:
    missing = sorted({zone.crop_id for zone in zones.values()} - set(crops.keys()))
    if missing:
        missing_str = ", ".join(missing)
        raise ValueError(f"zones.yaml references unknown crop_id(s): {missing_str}")
