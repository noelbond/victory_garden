from __future__ import annotations

import json
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


def save_state_store(path: Path, states: Dict[str, ZoneState]) -> None:
    payload = {zone_id: state.model_dump(mode="json") for zone_id, state in states.items()}
    path.write_text(json.dumps(payload, indent=2, sort_keys=True))


def get_zone_state(states: Dict[str, ZoneState], zone_id: str, default: ZoneState) -> ZoneState:
    return states.get(zone_id, default)
