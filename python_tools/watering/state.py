from __future__ import annotations

from datetime import date, datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class ZoneState(BaseModel):
    model_config = ConfigDict(extra="forbid")

    zone_id: str = Field(min_length=1, examples=["zone3"])
    day: date = Field(examples=["2026-02-06"])
    runtime_seconds_today: int = Field(default=0, ge=0, le=86_400, examples=[120])

    last_watered_at: Optional[datetime] = Field(default=None)
    last_moisture_percent: Optional[float] = Field(default=None, ge=0, le=100, examples=[31.4])
