from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

def utcnow() -> datetime:
    return datetime.now(tz=timezone.utc)

class SensorReading(BaseModel):
    model_config = ConfigDict(extra="forbid")

    node_id: str = Field(min_length=1, examples=["sensor-gh1-zone3"])
    zone_id: str = Field(min_length=1, examples=["zone3"])

    timestamp: datetime = Field(default_factory=utcnow)

    moisture_raw: int = Field(ge=0, le=65535, examples=[1820])
    moisture_percent: Optional[float] = Field(default=None, ge=0, le=100, examples=[31.4])

    battery_voltage: Optional[float] = Field(default=None, ge=0, le=10, examples=[3.78])
    rssi: Optional[int] = Field(default=None, ge=-130, le=0, examples=[-67])

class HubCommand(str, Enum):
    START_WATER = "start_watering"
    STOP_WATER = "stop_watering"


class WaterCommand(BaseModel):
    model_config = ConfigDict(extra="forbid")

    command: HubCommand = Field(examples=[HubCommand.START_WATER])
    zone_id: str = Field(min_length=1, examples=["zone3"])

    runtime_seconds: Optional[int] = Field(ge=0, le=3600, examples=[45])
    reason: Optional[str] = Field(default=None, max_length=200, examples=["below_dry_threshold"])

    issued_at: datetime = Field(default_factory=utcnow)
    idempotency_key: str = Field(min_length=8, examples=["gh1-zone3-20260129T150000Z-1"])

    def model_post_init(self, __context) -> None:
        if self.command == HubCommand.STOP_WATER and self.runtime_seconds is not None:
            raise ValueError("runtime_seconds must be None when command is STOP_WATER")



class ActuatorState(str, Enum):
    ACKNOWLEDGED = "ACKNOWLEDGED"
    RUNNING = "RUNNING"
    COMPLETED = "COMPLETED"
    STOPPED = "STOPPED"
    FAULT = "FAULT"

class ActuatorStatus(BaseModel):
    model_config = ConfigDict(extra="forbid")

    zone_id: str = Field(min_length=1, examples=["zone3"])
    state: ActuatorState = Field(examples=[ActuatorState.RUNNING])

    timestamp: datetime = Field(default_factory=utcnow)

    idempotency_key: Optional[str] = Field(default=None, min_length=8)

    actual_runtime_seconds: Optional[int] = Field(default=None, ge=0, le=3600)
    flow_ml: Optional[int] = Field(default=None, ge=0, le=10_000_000)
    fault_code: Optional[str] = Field(default=None, max_length=50, examples=["NO_FLOW", "OVER_FLOW"])
    fault_detail: Optional[str] = Field(default=None, max_length=300)
