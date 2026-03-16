from __future__ import annotations

from pydantic import AliasChoices, BaseModel, ConfigDict, Field


class CropProfile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    crop_id: str = Field(min_length=1, examples=["tomato"])
    crop_name: str = Field(min_length=1, examples=["Tomato"])
    dry_threshold: float = Field(ge=0, le=100, examples=[28.5])
    max_pulse_runtime_sec: int = Field(
        ge=0,
        le=3600,
        examples=[45],
        validation_alias=AliasChoices("max_pulse_runtime_sec", "runtime_seconds"),
        serialization_alias="max_pulse_runtime_sec",
    )
    daily_max_runtime_sec: int = Field(
        ge=0,
        le=3600,
        examples=[300],
        validation_alias=AliasChoices("daily_max_runtime_sec", "max_daily_runtime_seconds"),
        serialization_alias="daily_max_runtime_sec",
    )
    climate_preference: str | None = Field(default=None, max_length=200, examples=["Warm, sunny"])
    time_to_harvest_days: int | None = Field(default=None, ge=0, examples=[75])

    @property
    def runtime_seconds(self) -> int:
        return self.max_pulse_runtime_sec

    @property
    def max_daily_runtime_seconds(self) -> int:
        return self.daily_max_runtime_sec
