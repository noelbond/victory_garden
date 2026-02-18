from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class CropProfile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    crop_id: str = Field(min_length=1, examples=["tomato"])
    crop_name: str = Field(min_length=1, examples=["Tomato"])
    dry_threshold: float = Field(ge=0, le=100, examples=[28.5])
    runtime_seconds: int = Field(ge=0, le=3600, examples=[45])
    max_daily_runtime_seconds: int = Field(ge=0, le=3600, examples=[300])
