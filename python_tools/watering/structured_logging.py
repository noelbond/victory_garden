from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
import json
from pathlib import Path
from typing import Any


def _normalize(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, Path):
        return str(value)
    if hasattr(value, "model_dump"):
        return _normalize(value.model_dump())
    if isinstance(value, dict):
        return {str(key): _normalize(val) for key, val in value.items()}
    if isinstance(value, (list, tuple)):
        return [_normalize(item) for item in value]
    return value


def log_event(component: str, event: str, level: str = "info", **fields: Any) -> None:
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "component": component,
        "event": event,
    }
    payload.update({key: _normalize(value) for key, value in fields.items()})
    print(json.dumps(payload, sort_keys=True), flush=True)
