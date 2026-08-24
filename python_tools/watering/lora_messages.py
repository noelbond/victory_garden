from __future__ import annotations

from datetime import datetime
import json
import re
from typing import Any, Literal, Mapping

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

LORA_COMMAND_SCHEMA_VERSION = "lora-command/v1"
LORA_COMMAND_REQUEST_READING = "request_reading"
COMPACT_LORA_COMMAND_TYPE = "cmd"
COMPACT_LORA_COMMAND_REQUEST_READING = "rr"
LORA_COMMAND_ACK_SCHEMA_VERSION = "lora-command-ack/v1"
LORA_COMMAND_ACK_TARGET = "pi-gateway"
MQTT_SAFE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
DEFAULT_LORA_MAX_FRAME_SIZE = 1024
LORA_COMMAND_TOPIC_PREFIX = "greenhouse/nodes/"
LORA_COMMAND_TOPIC_SUFFIX = "/lora/command"
LORA_COMMAND_TOPIC_FILTER = f"{LORA_COMMAND_TOPIC_PREFIX}+{LORA_COMMAND_TOPIC_SUFFIX}"
LORA_COMMAND_ACK_TOPIC_SUFFIX = "/lora/command_ack"


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


class LoRaCommandAck(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[LORA_COMMAND_ACK_SCHEMA_VERSION]
    message_id: str = Field(min_length=1, max_length=120)
    timestamp: datetime
    source_node_id: str = Field(min_length=1, max_length=120)
    target: str = Field(min_length=1, max_length=80)
    ack_for_message_id: str = Field(min_length=1, max_length=120)
    status: Literal["acknowledged", "rejected", "failed", "duplicate"]
    error: str | None = Field(default=None, max_length=200)

    @field_validator("message_id", "source_node_id", "target", "ack_for_message_id")
    @classmethod
    def validate_mqtt_safe_identifier(cls, value: str) -> str:
        if not MQTT_SAFE_ID_PATTERN.fullmatch(value):
            raise ValueError("must be MQTT-safe")
        return value

    @model_validator(mode="after")
    def validate_error_matches_status(self) -> LoRaCommandAck:
        if self.status == "acknowledged" and self.error is not None:
            raise ValueError("error must be null for acknowledged acks")
        if self.status != "acknowledged" and not self.error:
            raise ValueError("error is required for non-acknowledged acks")
        return self


class InvalidLoRaCommandMessageError(ValueError):
    def __init__(self, *, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


def validate_lora_command(payload: Mapping[str, Any]) -> LoRaCommand:
    return LoRaCommand.model_validate(payload)


def validate_lora_command_ack(payload: Mapping[str, Any]) -> LoRaCommandAck:
    return LoRaCommandAck.model_validate(payload)


def canonical_lora_command_ack_topic(ack: LoRaCommandAck) -> str:
    return f"{LORA_COMMAND_TOPIC_PREFIX}{ack.source_node_id}{LORA_COMMAND_ACK_TOPIC_SUFFIX}"


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
    sequence: int | None = None,
) -> bytes:
    if max_frame_size < 1:
        raise ValueError("max_frame_size must be at least 1")
    if sequence is not None and sequence < 1:
        raise ValueError("sequence must be at least 1")

    validated = command if isinstance(command, LoRaCommand) else validate_lora_command(command)
    payload = {
        "t": COMPACT_LORA_COMMAND_TYPE,
        "c": COMPACT_LORA_COMMAND_REQUEST_READING,
        "n": validated.target_node_id,
        "mid": validated.message_id,
    }
    if sequence is not None:
        payload["sq"] = sequence

    frame = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(frame) > max_frame_size:
        raise ValueError("serialized LoRa command frame exceeds max_frame_size")

    return frame
