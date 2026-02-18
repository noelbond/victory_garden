from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4
from typing import Optional

from watering.profiles import CropProfile
from watering.schemas import HubCommand, SensorReading, WaterCommand
from watering.state import ZoneState


def _utcnow() -> datetime:
    return datetime.now(tz=timezone.utc)


def decide_watering(
    reading: SensorReading,
    profile: CropProfile,
    state: ZoneState,
    now: Optional[datetime] = None,
) -> tuple[Optional[WaterCommand], ZoneState]:
    
    now = now or _utcnow()
    today = now.date()
    if reading.zone_id != state.zone_id:
        raise ValueError(
            f"Zone mismatch: reading.zone_id={reading.zone_id} state.zone_id={state.zone_id}"
        )

    if state.day != today:
        state = state.model_copy(update={"day": today, "runtime_seconds_today": 0})

    moisture = reading.moisture_percent
    state = state.model_copy(update={"last_moisture_percent": moisture})

    if moisture is None:
        return None, state

    if moisture >= profile.dry_threshold:
        return None, state

    if state.runtime_seconds_today >= profile.max_daily_runtime_seconds:
        return None, state

    remaining = profile.max_daily_runtime_seconds - state.runtime_seconds_today
    runtime = min(profile.runtime_seconds, remaining)
    if runtime <= 0:
        return None, state

    cmd = WaterCommand(
        command=HubCommand.START_WATER,
        zone_id=reading.zone_id,
        runtime_seconds=runtime,
        reason="below_dry_threshold",
        idempotency_key=f"{reading.zone_id}-{now:%Y%m%dT%H%M%SZ}-{uuid4().hex[:8]}",
    )

    state = state.model_copy(
        update={
            "runtime_seconds_today": state.runtime_seconds_today + runtime,
            "last_watered_at": now,
        }
    )
    return cmd, state
