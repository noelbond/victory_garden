import json

import pytest
from pydantic import ValidationError

from watering.lora_messages import LORA_COMMAND_SCHEMA_VERSION, validate_lora_command
from watering.lora_transmitter import (
    LoRaCommandRetryController,
    LoRaCommandRouteResult,
    LoRaCommandRouteTarget,
    LoRaCommandRouter,
    LoRaCommandTransmitter,
)


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
        assert json.loads(frame.decode("utf-8")) == {
            "t": "cmd",
            "c": "rr",
            "n": "sensor-zone1-ch0",
            "mid": "pi-20260821T153000Z-abc123",
            "sq": 1,
        }

    def test_transmits_already_validated_command(self):
        stream = FakeSerialWriteStream()
        transmitter = LoRaCommandTransmitter(stream)
        command = validate_lora_command(lora_command_payload())

        frame = transmitter.transmit_command(command)

        assert stream.writes == [frame + b"\n"]
        assert stream.flushes == 1

    def test_increments_sequence_for_each_transmit(self):
        stream = FakeSerialWriteStream()
        transmitter = LoRaCommandTransmitter(stream, initial_sequence=41)

        first_frame = transmitter.transmit_command(lora_command_payload())
        second_frame = transmitter.transmit_command(lora_command_payload())

        assert json.loads(first_frame.decode("utf-8"))["sq"] == 41
        assert json.loads(second_frame.decode("utf-8"))["sq"] == 42

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

    def test_rejects_invalid_initial_sequence(self):
        with pytest.raises(ValueError, match="initial_sequence must be at least 1"):
            LoRaCommandTransmitter(FakeSerialWriteStream(), initial_sequence=0)


class FakeTransmitter:
    def __init__(self, *, error=None):
        self.error = error
        self.commands = []
        self.frames = []

    def transmit_command(self, command):
        if self.error is not None:
            raise self.error

        self.commands.append(command)
        return b'{"ok":true}'

    def transmit_frame(self, frame):
        if self.error is not None:
            raise self.error

        self.frames.append(frame)
        return frame


class FakeRetryTimer:
    def __init__(self, delay_seconds, callback):
        self.delay_seconds = delay_seconds
        self.callback = callback
        self.started = False
        self.cancelled = False

    def start(self):
        self.started = True

    def cancel(self):
        self.cancelled = True

    def fire(self):
        self.callback()


class FakeRetryTimerFactory:
    def __init__(self):
        self.timers = []

    def __call__(self, delay_seconds, callback):
        timer = FakeRetryTimer(delay_seconds, callback)
        self.timers.append(timer)
        return timer


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

    def test_routes_repeated_message_id_as_exact_same_frame(self):
        stream = FakeSerialWriteStream()
        router = LoRaCommandRouter(LoRaCommandTransmitter(stream, initial_sequence=42))
        topic = "greenhouse/nodes/sensor-zone1-ch0/lora/command"
        payload = json.dumps(lora_command_payload()).encode("utf-8")

        first_result = router.route_mqtt_command(topic, payload)
        second_result = router.route_mqtt_command(topic, payload)

        assert first_result.accepted is True
        assert second_result.accepted is True
        assert len(stream.writes) == 2
        assert stream.writes[0] == stream.writes[1]
        assert json.loads(stream.writes[0].rstrip(b"\n").decode("utf-8"))["sq"] == 42

    def test_rejects_reused_message_id_with_different_payload(self):
        stream = FakeSerialWriteStream()
        router = LoRaCommandRouter(LoRaCommandTransmitter(stream, initial_sequence=42))
        topic = "greenhouse/nodes/sensor-zone1-ch0/lora/command"
        payload = json.dumps(lora_command_payload()).encode("utf-8")
        changed_payload = json.dumps(lora_command_payload(source="rails-server")).encode("utf-8")

        first_result = router.route_mqtt_command(topic, payload)
        second_result = router.route_mqtt_command(topic, changed_payload)

        assert first_result.accepted is True
        assert second_result == LoRaCommandRouteResult(
            accepted=False,
            reason="duplicate_message_id_payload_mismatch",
            topic=topic,
            target_node_id="sensor-zone1-ch0",
            message_id="pi-20260821T153000Z-abc123",
        )
        assert len(stream.writes) == 1

    def test_rejects_invalid_recent_command_frame_cache_size(self):
        with pytest.raises(ValueError, match="recent_command_frames must be at least 1"):
            LoRaCommandRouter(FakeTransmitter(), recent_command_frames=0)

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
        assert result.target_node_id == "sensor-zone1-ch0"
        assert result.message_id == "pi-20260821T153000Z-abc123"

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
        assert disconnected_result.target_node_id == "sensor-zone1-ch0"
        assert disconnected_result.message_id == "pi-20260821T153000Z-abc123"
        assert len(transmitter.commands) == 1


class TestLoRaCommandRetryController:
    def test_retries_exact_same_serialized_command_frame(self):
        stream = FakeSerialWriteStream()
        router = LoRaCommandRouter(LoRaCommandTransmitter(stream, initial_sequence=9))
        timer_factory = FakeRetryTimerFactory()
        topic = "greenhouse/nodes/sensor-zone1-ch0/lora/command"
        payload = json.dumps(lora_command_payload()).encode("utf-8")
        controller = LoRaCommandRetryController(
            router.route_mqtt_command,
            max_attempts=2,
            retry_delay_seconds=5.0,
            timer_factory=timer_factory,
        )

        controller.route_mqtt_command(topic, payload)
        timer_factory.timers[0].fire()

        assert len(stream.writes) == 2
        assert stream.writes[0] == stream.writes[1]
        assert json.loads(stream.writes[0].rstrip(b"\n").decode("utf-8"))["sq"] == 9

    def test_retries_accepted_command_until_marked_completed(self):
        route_calls = []
        retry_results = []
        timer_factory = FakeRetryTimerFactory()

        def route_command(topic, payload):
            route_calls.append((topic, payload))
            return LoRaCommandRouteResult(
                accepted=True,
                topic=topic,
                target_node_id="sensor-zone1-ch0",
                message_id="pi-20260821T153000Z-abc123",
                frame_size=78,
            )

        controller = LoRaCommandRetryController(
            route_command,
            max_attempts=3,
            retry_delay_seconds=5.0,
            timer_factory=timer_factory,
            on_retry_result=retry_results.append,
        )

        result = controller.route_mqtt_command(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            b'{"schema_version":"lora-command/v1"}',
        )
        timer_factory.timers[0].fire()
        controller.mark_command_completed("pi-20260821T153000Z-abc123")

        assert result.accepted is True
        assert len(route_calls) == 2
        assert len(retry_results) == 1
        assert len(timer_factory.timers) == 2
        assert timer_factory.timers[0].delay_seconds == 5.0
        assert timer_factory.timers[0].started is True
        assert timer_factory.timers[1].started is True
        assert timer_factory.timers[1].cancelled is True

    def test_stops_after_max_attempts(self):
        route_calls = []
        retry_results = []
        timer_factory = FakeRetryTimerFactory()

        def route_command(topic, payload):
            route_calls.append((topic, payload))
            return LoRaCommandRouteResult(
                accepted=True,
                topic=topic,
                target_node_id="sensor-zone1-ch0",
                message_id="pi-20260821T153000Z-abc123",
                frame_size=78,
            )

        controller = LoRaCommandRetryController(
            route_command,
            max_attempts=2,
            retry_delay_seconds=5.0,
            timer_factory=timer_factory,
            on_retry_result=retry_results.append,
        )

        controller.route_mqtt_command(
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            b'{"schema_version":"lora-command/v1"}',
        )
        timer_factory.timers[0].fire()

        assert len(route_calls) == 2
        assert len(timer_factory.timers) == 1
        assert retry_results[-1] == LoRaCommandRouteResult(
            accepted=False,
            reason="retry_exhausted",
            topic="greenhouse/nodes/sensor-zone1-ch0/lora/command",
            message_id="pi-20260821T153000Z-abc123",
        )

    def test_does_not_track_rejected_command_or_single_attempt_mode(self):
        timer_factory = FakeRetryTimerFactory()

        rejected_controller = LoRaCommandRetryController(
            lambda topic, _payload: LoRaCommandRouteResult(accepted=False, reason="ValueError", topic=topic),
            timer_factory=timer_factory,
        )
        single_attempt_controller = LoRaCommandRetryController(
            lambda topic, _payload: LoRaCommandRouteResult(
                accepted=True,
                topic=topic,
                target_node_id="sensor-zone1-ch0",
                message_id="pi-20260821T153000Z-abc123",
                frame_size=78,
            ),
            max_attempts=1,
            timer_factory=timer_factory,
        )

        rejected_controller.route_mqtt_command("greenhouse/nodes/node1/lora/command", b"{}")
        single_attempt_controller.route_mqtt_command("greenhouse/nodes/node1/lora/command", b"{}")

        assert timer_factory.timers == []

    def test_rejects_invalid_retry_settings(self):
        with pytest.raises(ValueError, match="max_attempts must be at least 1"):
            LoRaCommandRetryController(lambda _topic, _payload: LoRaCommandRouteResult(accepted=True), max_attempts=0)
        with pytest.raises(ValueError, match="retry_delay_seconds must be at least 0"):
            LoRaCommandRetryController(
                lambda _topic, _payload: LoRaCommandRouteResult(accepted=True),
                retry_delay_seconds=-1,
            )
