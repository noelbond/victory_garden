from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict

from watering.state import ZoneState


def load_state_store(path: Path) -> Dict[str, ZoneState]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("State store JSON must be an object mapping zone_id to state data.")
    return {zone_id: ZoneState.model_validate(payload) for zone_id, payload in data.items()}


def serialize_state_store(states: Dict[str, ZoneState]) -> str:
    payload = {zone_id: state.model_dump(mode="json") for zone_id, state in states.items()}
    return json.dumps(payload, indent=2, sort_keys=True)


def atomic_write_text(path: Path, text: str) -> None:
    tmp_path = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp_path.write_text(text)
    tmp_path.replace(path)


def save_state_store(path: Path, states: Dict[str, ZoneState]) -> None:
    atomic_write_text(path, serialize_state_store(states))


def quarantine_invalid_json_file(path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    quarantined = path.with_name(f"{path.stem}.corrupt-{timestamp}{path.suffix}")
    path.replace(quarantined)
    return quarantined


def quarantine_invalid_state_store(path: Path) -> Path:
    return quarantine_invalid_json_file(path)


def load_state_store_resilient(path: Path) -> tuple[Dict[str, ZoneState], Path | None, str | None]:
    if not path.exists():
        return {}, None, None

    try:
        return load_state_store(path), None, None
    except (json.JSONDecodeError, ValueError) as exc:
        quarantined = quarantine_invalid_state_store(path)
        return {}, quarantined, str(exc)


def get_zone_state(states: Dict[str, ZoneState], zone_id: str, default: ZoneState) -> ZoneState:
    return states.get(zone_id, default)
