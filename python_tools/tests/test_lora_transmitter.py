import json

import pytest
from pydantic import ValidationError

from watering.lora_messages import LORA_COMMAND_SCHEMA_VERSION, validate_lora_command
from watering.lora_transmitter import LoRaCommandRouteTarget, LoRaCommandRouter, LoRaCommandTransmitter


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


class FakeSerialWriteStream:
    def __init__(self):
        self.writes = []
        self.flushes = 0

    def write(self, data):
        self.writes.append(data)
        return len(data)

    def flush(self):
        self.flushes += 1


class TestLoRaCommandTransmitter:
    def test_transmits_valid_mapping_as_one_newline_delimited_frame(self):
        stream = FakeSerialWriteStream()
        transmitter = LoRaCommandTransmitter(stream)

        frame = transmitter.transmit_command(lora_command_payload())

        assert stream.writes == [frame + b"\n"]
        assert stream.flushes == 1
        assert json.loads(frame.decode("utf-8")) == lora_command_payload()

    def test_transmits_already_validated_command(self):
        stream = FakeSerialWriteStream()
        transmitter = LoRaCommandTransmitter(stream)
        command = validate_lora_command(lora_command_payload())

        frame = transmitter.transmit_command(command)

        assert stream.writes == [frame + b"\n"]
        assert stream.flushes == 1

    def test_rejects_invalid_command_before_writing(self):
        stream = FakeSerialWriteStream()
        transmitter = LoRaCommandTransmitter(stream)

        with pytest.raises(ValidationError):
            transmitter.transmit_command(lora_command_payload(command="reboot"))

        assert stream.writes == []
        assert stream.flushes == 0

    def test_rejects_oversized_serialized_command_before_writing(self):
        stream = FakeSerialWriteStream()
        transmitter = LoRaCommandTransmitter(stream, max_frame_size=10)

        with pytest.raises(ValueError, match="exceeds max_frame_size"):
            transmitter.transmit_command(lora_command_payload())

        assert stream.writes == []
        assert stream.flushes == 0

    def test_rejects_invalid_max_frame_size(self):
        with pytest.raises(ValueError, match="max_frame_size must be at least 1"):
            LoRaCommandTransmitter(FakeSerialWriteStream(), max_frame_size=0)


class FakeTransmitter:
    def __init__(self, *, error=None):
        self.error = error
        self.commands = []

    def transmit_command(self, command):
        if self.error is not None:
            raise self.error

        self.commands.append(command)
        return b'{"ok":true}'


class TestLoRaCommandRouter:
    def test_routes_valid_mqtt_command_to_transmitter(self):
        transmitter = FakeTransmitter()
        router = LoRaCommandRouter(transmitter)

        result = router.route_mqtt_command(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            json.dumps(lora_command_payload()).encode("utf-8"),
        )

        assert result.accepted is True
        assert result.reason is None
        assert result.topic == "greenhouse/nodes/sensor-zone1-ch0/lora/command"
        assert result.target_node_id == "sensor-zone1-ch0"
        assert result.message_id == "pi-20260821T153000Z-abc123"
        assert result.frame_size == len(b'{"ok":true}')
        assert len(transmitter.commands) == 1
        assert transmitter.commands[0].target_node_id == "sensor-zone1-ch0"

    @pytest.mark.parametrize(
        ("topic", "payload", "reason"),
        [
            (
                "greenhouse/zones/zone1/lora/command",
                json.dumps(lora_command_payload()).encode("utf-8"),
                "ValueError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                b"{",
                "JSONDecodeError",
            ),
            (
                "greenhouse/nodes/sensor-zone1-ch0/lora/command",
                json.dumps(lora_command_payload(target_node_id="sensor-zone1-ch1")).encode("utf-8"),
                "ValueError",
            ),
        ],
    )
    def test_rejects_invalid_mqtt_command_without_transmitting(self, topic, payload, reason):
        transmitter = FakeTransmitter()
        router = LoRaCommandRouter(transmitter)

        result = router.route_mqtt_command(topic, payload)

        assert result.accepted is False
        assert result.reason == reason
        assert result.topic == topic
        assert transmitter.commands == []

    def test_reports_transmitter_value_error_without_raising(self):
        transmitter = FakeTransmitter(error=ValueError("too large"))
        router = LoRaCommandRouter(transmitter)

        result = router.route_mqtt_command(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            json.dumps(lora_command_payload()).encode("utf-8"),
        )

        assert result.accepted is False
        assert result.reason == "ValueError"
        assert transmitter.commands == []

    def test_reports_transmitter_os_error_without_raising(self):
        transmitter = FakeTransmitter(error=OSError("usb gone"))
        router = LoRaCommandRouter(transmitter)

        result = router.route_mqtt_command(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            json.dumps(lora_command_payload()).encode("utf-8"),
        )

        assert result.accepted is False
        assert result.reason == "OSError"
        assert transmitter.commands == []


class TestLoRaCommandRouteTarget:
    def test_reports_serial_disconnected_until_router_is_set(self):
        target = LoRaCommandRouteTarget()

        result = target.route_mqtt_command(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            json.dumps(lora_command_payload()).encode("utf-8"),
        )

        assert result.accepted is False
        assert result.reason == "serial_disconnected"

    def test_routes_to_current_router_and_stops_after_clear(self):
        transmitter = FakeTransmitter()
        router = LoRaCommandRouter(transmitter)
        target = LoRaCommandRouteTarget()
        topic = "greenhouse/nodes/sensor-zone1-ch0/lora/command"
        payload = json.dumps(lora_command_payload()).encode("utf-8")

        target.set_router(router)
        accepted_result = target.route_mqtt_command(topic, payload)
        target.clear_router(router)
        disconnected_result = target.route_mqtt_command(topic, payload)

        assert accepted_result.accepted is True
        assert disconnected_result.accepted is False
        assert disconnected_result.reason == "serial_disconnected"
        assert len(transmitter.commands) == 1
