from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
import json
import threading
from typing import Any

import paho.mqtt.client as mqtt

from watering.config import SystemZoneConfig, ZoneConfig
from watering.profiles import CropProfile
from watering.schemas import SensorReading
from watering.state_store import (
    atomic_write_text,
    quarantine_invalid_json_file,
)
from watering.structured_logging import log_event


SYSTEM_CONFIG_TOPIC = "greenhouse/system/config/current"
CANONICAL_NODE_STATE_TOPIC = "greenhouse/zones/{zone_id}/nodes/+/state"


@dataclass
class ControllerRuntime:
    latest_state: dict[str, SensorReading] = field(default_factory=dict)
    latest_zone_readings: dict[str, dict[str, SensorReading]] = field(default_factory=dict)
    live_crops: dict[str, CropProfile] = field(default_factory=dict)
    live_zones: dict[str, SystemZoneConfig] = field(default_factory=dict)
    subscribed_state_topics: set[str] = field(default_factory=set)
    subscription_fallback_zones: dict[str, ZoneConfig] = field(default_factory=dict)
    subscription_zone_filter: set[str] | None = None
    subscriber_client: mqtt.Client | None = None
    controller_health: dict[str, Any] = field(default_factory=dict)
    live_config_lock: threading.RLock = field(default_factory=threading.RLock)
    latest_state_lock: threading.RLock = field(default_factory=threading.RLock)
    subscription_lock: threading.RLock = field(default_factory=threading.RLock)
    controller_health_lock: threading.RLock = field(default_factory=threading.RLock)


CONTROLLER_RUNTIME = ControllerRuntime()

LATEST_STATE = CONTROLLER_RUNTIME.latest_state
LATEST_ZONE_READINGS = CONTROLLER_RUNTIME.latest_zone_readings
LIVE_CROPS = CONTROLLER_RUNTIME.live_crops
LIVE_ZONES = CONTROLLER_RUNTIME.live_zones
SUBSCRIBED_STATE_TOPICS = CONTROLLER_RUNTIME.subscribed_state_topics
CONTROLLER_HEALTH = CONTROLLER_RUNTIME.controller_health


def new_zone_runtime() -> dict[str, Any]:
    return {
        "last_processed_signature": None,
        "last_watering_signature": None,
        "last_watering_at": None,
        "last_skip_signature": None,
        "last_skip_reason": None,
    }


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def new_controller_health() -> dict[str, Any]:
    return {
        "component": "controller",
        "status": "starting",
        "updated_at": iso_now(),
        "publisher_connected": False,
        "subscriber_connected": False,
        "startup_complete": False,
        "last_sensor_message_at": None,
        "last_sensor_zone_id": None,
        "last_system_config_at": None,
        "last_decision_at": None,
        "last_decision_zone_id": None,
        "last_decision_action": None,
        "last_loop_at": None,
        "last_error": None,
    }


def update_controller_health(**fields: Any) -> None:
    with CONTROLLER_RUNTIME.controller_health_lock:
        if not CONTROLLER_RUNTIME.controller_health:
            CONTROLLER_RUNTIME.controller_health.update(new_controller_health())
        CONTROLLER_RUNTIME.controller_health.update(fields)
        CONTROLLER_RUNTIME.controller_health["updated_at"] = iso_now()


def controller_health_snapshot() -> dict[str, Any]:
    with CONTROLLER_RUNTIME.controller_health_lock:
        if not CONTROLLER_RUNTIME.controller_health:
            CONTROLLER_RUNTIME.controller_health.update(new_controller_health())
        return dict(CONTROLLER_RUNTIME.controller_health)


def serialize_controller_health(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def serialize_controller_runtime(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def write_text_if_changed(path: Path, text: str, previous: str | None) -> str:
    if text == previous:
        return previous if previous is not None else text
    atomic_write_text(path, text)
    return text


def live_config_snapshot() -> tuple[dict[str, CropProfile], dict[str, SystemZoneConfig]]:
    with CONTROLLER_RUNTIME.live_config_lock:
        return dict(CONTROLLER_RUNTIME.live_crops), dict(CONTROLLER_RUNTIME.live_zones)


def latest_reading(zone_id: str) -> SensorReading | None:
    with CONTROLLER_RUNTIME.latest_state_lock:
        return CONTROLLER_RUNTIME.latest_state.get(zone_id)


def store_latest_reading(reading: SensorReading) -> None:
    with CONTROLLER_RUNTIME.latest_state_lock:
        CONTROLLER_RUNTIME.latest_state[reading.zone_id] = reading
        CONTROLLER_RUNTIME.latest_zone_readings.setdefault(reading.zone_id, {})[reading.node_id] = reading


def latest_readings_for_zone(zone_id: str) -> dict[str, SensorReading]:
    with CONTROLLER_RUNTIME.latest_state_lock:
        readings = dict(CONTROLLER_RUNTIME.latest_zone_readings.get(zone_id, {}))
        latest = CONTROLLER_RUNTIME.latest_state.get(zone_id)
        if latest is not None and latest.node_id not in readings:
            readings[latest.node_id] = latest
        return readings


def have_latest_state_for_any(zone_ids: list[str]) -> bool:
    with CONTROLLER_RUNTIME.latest_state_lock:
        return any(
            zone_id in CONTROLLER_RUNTIME.latest_state or zone_id in CONTROLLER_RUNTIME.latest_zone_readings
            for zone_id in zone_ids
        )


def load_controller_runtime(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ValueError("Controller runtime JSON must be an object mapping zone_id to runtime state.")
        return data
    except (json.JSONDecodeError, ValueError) as exc:
        quarantined = quarantine_invalid_json_file(path)
        log_event(
            "controller",
            "controller_runtime_invalid",
            level="warning",
            path=str(path),
            quarantined_path=str(quarantined),
            error=str(exc),
        )
        return {}


def save_controller_runtime(path: Path, data: dict[str, Any]) -> None:
    atomic_write_text(path, serialize_controller_runtime(data))
