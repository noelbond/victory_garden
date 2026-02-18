from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class CalibrationProfile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    raw_dry: int = Field(ge=0, le=65535, examples=[3000])
    raw_wet: int = Field(ge=0, le=65535, examples=[1200])


def raw_to_percent(raw: int, profile: CalibrationProfile) -> float:
    if profile.raw_dry == profile.raw_wet:
        return 0.0
    percent = (profile.raw_dry - raw) / (profile.raw_dry - profile.raw_wet) * 100.0
    return max(0.0, min(100.0, percent))
