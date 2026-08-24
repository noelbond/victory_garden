import json

import pytest
from pydantic import ValidationError

from watering.lora_messages import (
    InvalidLoRaCommandMessageError,
    LORA_COMMAND_SCHEMA_VERSION,
    LoRaCommand,
    build_lora_command_from_mqtt,
    parse_lora_command_topic,
    require_lora_command_target_match,
    serialize_lora_command_frame,
    validate_lora_command,
)
from watering.serial_frames import SerialFrameWriter


def lora_command_payload(**overrides):
    payload = {
        "schema_version": LORA_COMMAND_SCHEMA_VERSION,
        "message_id": "pi-20260821T153000Z-abc123",
        "timestamp": "2026-08-21T15:30:00Z",
        "source": "pi-gateway",
        "target_node_id": "sensor-zone1-ch0",
        "command": "request_reading",
        "args": {},
    }
    payload.update(overrides)
    return payload


def lora_command_bytes(**overrides):
    return json.dumps(lora_command_payload(**overrides), separators=(",", ":")).encode("utf-8")


class TestParseLoRaCommandTopic:
    def test_parses_node_specific_lora_command_topic(self):
        assert (
            parse_lora_command_topic("greenhouse/nodes/sensor-zone1-ch0/lora/command")
            == "sensor-zone1-ch0"
        )

    @pytest.mark.parametrize(
        "topic",
        [
            "greenhouse/zones/zone1/lora/command",
            "greenhouse/nodes/sensor-zone1-ch0/command",
            "greenhouse/nodes/sensor-zone1-ch0/lora/command/extra",
            "greenhouse/nodes//lora/command",
            "greenhouse/nodes/sensor/zone1/lora/command",
            "greenhouse/nodes/sensor#1/lora/command",
            "greenhouse/nodes/sensor zone1/lora/command",
        ],
    )
    def test_rejects_invalid_lora_command_topic(self, topic):
        with pytest.raises(ValueError):
            parse_lora_command_topic(topic)


class TestLoRaCommand:
    def test_validates_request_reading_command(self):
        command = validate_lora_command(lora_command_payload())

        assert isinstance(command, LoRaCommand)
        assert command.schema_version == "lora-command/v1"
        assert command.message_id == "pi-20260821T153000Z-abc123"
        assert command.source == "pi-gateway"
        assert command.target_node_id == "sensor-zone1-ch0"
        assert command.command == "request_reading"
        assert command.args == {}

    def test_rejects_wrong_schema_version(self):
        with pytest.raises(ValidationError):
            validate_lora_command(lora_command_payload(schema_version="node-command/v1"))

    def test_rejects_unsupported_command(self):
        with pytest.raises(ValidationError):
            validate_lora_command(lora_command_payload(command="reboot"))

    def test_rejects_extra_fields(self):
        with pytest.raises(ValidationError):
            validate_lora_command(lora_command_payload(extra="not allowed"))

    @pytest.mark.parametrize(
        ("field_name", "bad_value"),
        [
            ("message_id", "pi/command/1"),
            ("message_id", "pi command 1"),
            ("source", "pi/gateway"),
            ("target_node_id", "sensor#1"),
        ],
    )
    def test_rejects_non_mqtt_safe_identifiers(self, field_name, bad_value):
        with pytest.raises(ValidationError, match="must be MQTT-safe"):
            validate_lora_command(lora_command_payload(**{field_name: bad_value}))

    def test_rejects_request_reading_args(self):
        with pytest.raises(ValidationError, match="args must be empty for request_reading"):
            validate_lora_command(lora_command_payload(args={"reason": "manual"}))


class TestRequireLoRaCommandTargetMatch:
    def test_accepts_matching_topic_node_and_command_target(self):
        command = validate_lora_command(lora_command_payload(target_node_id="sensor-zone1-ch0"))

        require_lora_command_target_match("sensor-zone1-ch0", command)

    def test_rejects_mismatched_topic_node_and_command_target(self):
        command = validate_lora_command(lora_command_payload(target_node_id="sensor-zone1-ch0"))

        with pytest.raises(ValueError, match="must match target_node_id"):
            require_lora_command_target_match("sensor-zone1-ch1", command)


class TestBuildLoRaCommandFromMqtt:
    def test_builds_valid_command_from_matching_topic_and_payload(self):
        command = build_lora_command_from_mqtt(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            lora_command_bytes(target_node_id="sensor-zone1-ch0"),
        )

        assert command.target_node_id == "sensor-zone1-ch0"
        assert command.command == "request_reading"

    @pytest.mark.parametrize(
        ("topic", "payload", "reason"),
        [
            (
                "greenhouse/zones/zone1/lora/command",
                lora_command_bytes(),
                "ValueError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                b"\xff",
                "UnicodeDecodeError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                b"{",
                "JSONDecodeError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                b"[]",
                "ValueError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                lora_command_bytes(command="reboot"),
                "ValidationError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                lora_command_bytes(target_node_id="sensor-zone1-ch1"),
                "ValueError",
            ),
        ],
    )
    def test_wraps_invalid_mqtt_command_messages_with_reason(self, topic, payload, reason):
        with pytest.raises(InvalidLoRaCommandMessageError) as exc_info:
            build_lora_command_from_mqtt(topic, payload)

        assert exc_info.value.reason == reason


class TestSerializeLoRaCommandFrame:
    def test_serializes_valid_mapping_as_compact_utf8_json(self):
        frame = serialize_lora_command_frame(lora_command_payload())

        assert b"\n" not in frame
        assert b"\r" not in frame
        assert json.loads(frame.decode("utf-8")) == {
            "schema_version": "lora-command/v1",
            "message_id": "pi-20260821T153000Z-abc123",
            "timestamp": "2026-08-21T15:30:00Z",
            "source": "pi-gateway",
            "target_node_id": "sensor-zone1-ch0",
            "command": "request_reading",
            "args": {},
        }
        assert frame == (
            b'{"args":{},"command":"request_reading","message_id":"pi-20260821T153000Z-abc123",'
            b'"schema_version":"lora-command/v1","source":"pi-gateway","target_node_id":"sensor-zone1-ch0",'
            b'"timestamp":"2026-08-21T15:30:00Z"}'
        )

    def test_accepts_already_validated_command(self):
        command = validate_lora_command(lora_command_payload())

        assert serialize_lora_command_frame(command) == serialize_lora_command_frame(lora_command_payload())

    def test_rejects_invalid_mapping_before_serializing(self):
        with pytest.raises(ValidationError):
            serialize_lora_command_frame(lora_command_payload(command="reboot"))

    def test_rejects_frame_over_max_size(self):
        with pytest.raises(ValueError, match="exceeds max_frame_size"):
            serialize_lora_command_frame(lora_command_payload(), max_frame_size=10)

    def test_accepts_frame_at_max_size(self):
        frame = serialize_lora_command_frame(lora_command_payload())

        assert serialize_lora_command_frame(lora_command_payload(), max_frame_size=len(frame)) == frame

    def test_rejects_invalid_max_frame_size(self):
        with pytest.raises(ValueError, match="max_frame_size must be at least 1"):
            serialize_lora_command_frame(lora_command_payload(), max_frame_size=0)

    def test_serialized_command_can_be_written_as_one_serial_frame(self):
        class FakeWriteStream:
            def __init__(self):
                self.writes = []

            def write(self, data):
                self.writes.append(data)
                return len(data)

            def flush(self):
                pass

        stream = FakeWriteStream()
        frame = serialize_lora_command_frame(lora_command_payload())

        SerialFrameWriter(stream).write_frame(frame)

        assert stream.writes == [frame + b"\n"]
