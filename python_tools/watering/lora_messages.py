from __future__ import annotations

from datetime import datetime
import json
import re
from typing import Any, Literal, Mapping

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

LORA_COMMAND_SCHEMA_VERSION = "lora-command/v1"
LORA_COMMAND_REQUEST_READING = "request_reading"
MQTT_SAFE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
DEFAULT_LORA_MAX_FRAME_SIZE = 1024
LORA_COMMAND_TOPIC_PREFIX = "greenhouse/nodes/"
LORA_COMMAND_TOPIC_SUFFIX = "/lora/command"
LORA_COMMAND_TOPIC_FILTER = f"{LORA_COMMAND_TOPIC_PREFIX}+{LORA_COMMAND_TOPIC_SUFFIX}"


class LoRaCommand(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[LORA_COMMAND_SCHEMA_VERSION]
    message_id: str = Field(min_length=1, max_length=120)
    timestamp: datetime
    source: str = Field(min_length=1, max_length=80)
    target_node_id: str = Field(min_length=1, max_length=120)
    command: Literal["request_reading"]
    args: dict[str, Any] = Field(default_factory=dict)

    @field_validator("message_id", "source", "target_node_id")
    @classmethod
    def validate_mqtt_safe_identifier(cls, value: str) -> str:
        if not MQTT_SAFE_ID_PATTERN.fullmatch(value):
            raise ValueError("must be MQTT-safe")
        return value

    @model_validator(mode="after")
    def validate_command_args(self) -> LoRaCommand:
        if self.command == LORA_COMMAND_REQUEST_READING and self.args:
            raise ValueError("args must be empty for request_reading")
        return self


class InvalidLoRaCommandMessageError(ValueError):
    def __init__(self, *, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


def validate_lora_command(payload: Mapping[str, Any]) -> LoRaCommand:
    return LoRaCommand.model_validate(payload)


def parse_lora_command_topic(topic: str) -> str:
    if not topic.startswith(LORA_COMMAND_TOPIC_PREFIX) or not topic.endswith(LORA_COMMAND_TOPIC_SUFFIX):
        raise ValueError("invalid LoRa command topic")

    node_id = topic[len(LORA_COMMAND_TOPIC_PREFIX) : -len(LORA_COMMAND_TOPIC_SUFFIX)]
    if not node_id:
        raise ValueError("LoRa command topic missing node_id")
    if "/" in node_id:
        raise ValueError("LoRa command topic node_id must be a single path segment")
    if not MQTT_SAFE_ID_PATTERN.fullmatch(node_id):
        raise ValueError("LoRa command topic node_id must be MQTT-safe")

    return node_id


def require_lora_command_target_match(topic_node_id: str, command: LoRaCommand) -> None:
    if topic_node_id != command.target_node_id:
        raise ValueError("LoRa command topic node_id must match target_node_id")


def parse_json_object(payload: bytes) -> dict[str, Any]:
    parsed = json.loads(payload.decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("expected JSON object")
    return parsed


def build_lora_command_from_mqtt(topic: str, payload: bytes) -> LoRaCommand:
    try:
        topic_node_id = parse_lora_command_topic(topic)
        command = validate_lora_command(parse_json_object(payload))
        require_lora_command_target_match(topic_node_id, command)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise InvalidLoRaCommandMessageError(
            reason=type(exc).__name__,
            message=str(exc),
        ) from exc

    return command


def serialize_lora_command_frame(
    command: LoRaCommand | Mapping[str, Any],
    *,
    max_frame_size: int = DEFAULT_LORA_MAX_FRAME_SIZE,
) -> bytes:
    if max_frame_size < 1:
        raise ValueError("max_frame_size must be at least 1")

    validated = command if isinstance(command, LoRaCommand) else validate_lora_command(command)
    payload = validated.model_dump(mode="json")
    frame = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(frame) > max_frame_size:
        raise ValueError("serialized LoRa command frame exceeds max_frame_size")

    return frame
