import argparse
import json

import tools.lora_receiver as cli
from watering.lora_receiver import (
    LoRaReceiverTelemetry,
    NodeStatePublishResult,
    ShutdownController,
)
from watering.serial_frames import SerialFrameDecodeError


def node_state_frame(**overrides):
    payload = {
        "schema_version": "node-state/v1",
        "zone_id": "zone1",
        "node_id": "sensor-zone1-ch0",
        "moisture_raw": 1820,
    }
    payload.update(overrides)
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def command_ack_frame(**overrides):
    payload = {
        "schema_version": "lora-command-ack/v1",
        "message_id": "sensor-zone1-ch0-ack-123",
        "timestamp": "1970-01-01T00:00:00Z",
        "source_node_id": "sensor-zone1-ch0",
        "target": "pi-gateway",
        "ack_for_message_id": "pi-20260821T153000Z-abc123",
        "status": "acknowledged",
        "error": None,
    }
    payload.update(overrides)
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def compact_lora_state_frame(**overrides):
    payload = {
        "t": "state",
        "z": "zone1",
        "n": "sensor-zone1-ch0",
        "mid": "pi-001",
        "mr": 2345,
        "mp": 55,
        "up": 123,
    }
    payload.update(overrides)
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def args(**overrides):
    values = {
        "serial_port": "/dev/fake-lora",
        "baudrate": 9600,
        "serial_timeout_seconds": 1.0,
        "read_size": 256,
        "reconnect_delay_seconds": 0.0,
        "max_frame_size": 1024,
        "dedup_recent_frames": 32,
        "lora_command_max_attempts": 3,
        "lora_command_retry_delay_seconds": 6.0,
        "mqtt_host": None,
        "mqtt_port": None,
        "mqtt_username": None,
        "mqtt_password": None,
        "mqtt_max_queued_messages": 100,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class FakeShutdown(ShutdownController):
    def __init__(self):
        super().__init__()
        self.signal_handlers_installed = False

    def install_signal_handlers(self, **_kwargs):
        self.signal_handlers_installed = True


class FakePublisher:
    def __init__(self, *, accepted=True, reason=None):
        self.accepted = accepted
        self.reason = reason
        self.requests = []
        self.closed = False

    def publish_node_state(self, request):
        self.requests.append(request)
        return NodeStatePublishResult(accepted=self.accepted, reason=self.reason)

    def close(self):
        self.closed = True


class FakeReader:
    def __init__(self, actions, *, stream=None):
        self.actions = list(actions)
        self.run_kwargs = None
        self.stream = stream

    def run(self, **kwargs):
        self.run_kwargs = kwargs
        kwargs["on_serial_connected"]()
        serial_ready_cleanup = kwargs["on_serial_ready"](self.stream) if self.stream is not None else None
        for action in self.actions:
            if action[0] == "frame":
                kwargs["on_frame"](action[1])
            elif action[0] == "decode_error":
                kwargs["on_decode_error"](action[1])
            elif action[0] == "disconnect":
                kwargs["on_serial_disconnected"](action[1])
            elif action[0] == "call":
                action[1]()
        if serial_ready_cleanup is not None:
            serial_ready_cleanup()


class FakeSerialGatewayStream:
    def __init__(self):
        self.writes = []
        self.flushes = 0

    def read(self, _size=1):
        return b""

    def write(self, data):
        self.writes.append(data)
        return len(data)

    def flush(self):
        self.flushes += 1

    def close(self):
        pass


def test_runtime_publishes_valid_fake_serial_frames_and_cleans_up():
    shutdown = FakeShutdown()
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher()
    frame = node_state_frame()
    reader = FakeReader([("frame", frame)])

    cli.run_receiver(
        args(),
        shutdown=shutdown,
        telemetry=telemetry,
        publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
        reader_factory=lambda _args: reader,
    )

    assert shutdown.signal_handlers_installed is True
    assert len(publisher.requests) == 1
    assert publisher.requests[0].topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
    assert publisher.requests[0].payload == frame
    assert publisher.closed is True
    assert telemetry.counters.serial_connects == 1
    assert telemetry.counters.frames_received == 1
    assert telemetry.counters.frames_published == 1


def test_runtime_publishes_command_ack_fake_serial_frame():
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher()
    frame = command_ack_frame()
    reader = FakeReader([("frame", frame)])

    cli.run_receiver(
        args(),
        shutdown=FakeShutdown(),
        telemetry=telemetry,
        publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
        reader_factory=lambda _args: reader,
    )

    assert len(publisher.requests) == 1
    assert publisher.requests[0].topic == "greenhouse/nodes/sensor-zone1-ch0/lora/command_ack"
    assert publisher.requests[0].payload == frame
    assert telemetry.counters.frames_received == 1
    assert telemetry.counters.frames_published == 1


def test_runtime_translates_compact_lora_state_fake_serial_frame():
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher()
    frame = compact_lora_state_frame()
    reader = FakeReader([("frame", frame)])

    cli.run_receiver(
        args(),
        shutdown=FakeShutdown(),
        telemetry=telemetry,
        publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
        reader_factory=lambda _args: reader,
    )

    assert len(publisher.requests) == 1
    assert publisher.requests[0].topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
    payload = json.loads(publisher.requests[0].payload.decode("utf-8"))
    assert payload["schema_version"] == "node-state/v1"
    assert payload["moisture_raw"] == 2345
    assert payload["moisture_percent"] == 55
    assert payload["uptime_seconds"] == 123
    assert payload["publish_reason"] == "request_reading"
    assert payload["command_message_id"] == "pi-001"
    assert publisher.requests[0].payload != frame
    assert telemetry.counters.frames_received == 1
    assert telemetry.counters.frames_published == 1


def test_runtime_counts_invalid_and_decode_error_fake_serial_frames():
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher()
    decode_error = SerialFrameDecodeError(
        reason="frame_too_large",
        message="serial frame exceeds max_frame_size",
    )
    reader = FakeReader(
        [
            ("decode_error", decode_error),
            ("frame", b"{"),
            ("frame", node_state_frame(schema_version="wrong/v1")),
        ]
    )

    cli.run_receiver(
        args(),
        shutdown=FakeShutdown(),
        telemetry=telemetry,
        publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
        reader_factory=lambda _args: reader,
    )

    assert publisher.requests == []
    assert telemetry.counters.decoder_errors == 1
    assert telemetry.counters.frames_received == 2
    assert telemetry.counters.invalid_frames == 2


def test_runtime_records_publish_drop_from_fake_publisher():
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher(accepted=False, reason="mqtt_disconnected")
    reader = FakeReader([("frame", node_state_frame())])

    cli.run_receiver(
        args(),
        shutdown=FakeShutdown(),
        telemetry=telemetry,
        publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
        reader_factory=lambda _args: reader,
    )

    assert len(publisher.requests) == 1
    assert telemetry.counters.frames_published == 0
    assert telemetry.counters.frames_dropped == 1


def test_runtime_wires_serial_disconnect_callback_from_fake_reader():
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher()
    reader = FakeReader([("disconnect", RuntimeError("usb gone"))])

    cli.run_receiver(
        args(),
        shutdown=FakeShutdown(),
        telemetry=telemetry,
        publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
        reader_factory=lambda _args: reader,
    )


def test_runtime_routes_lora_mqtt_command_to_live_serial_stream():
    telemetry = LoRaReceiverTelemetry()
    publisher = FakePublisher()
    stream = FakeSerialGatewayStream()
    command_payload = {
        "schema_version": "lora-command/v1",
        "message_id": "pi-20260821T153000Z-abc123",
        "timestamp": "2026-08-21T15:30:00Z",
        "source": "pi-gateway",
        "target_node_id": "sensor-zone1-ch0",
        "command": "request_reading",
        "args": {},
    }
    captured = {}

    def publisher_factory(_args, _telemetry, command_route_handler):
        captured["command_route_handler"] = command_route_handler
        return publisher

    def route_command():
        captured["route_result"] = captured["command_route_handler"](
            "greenhouse/nodes/sensor-zone1-ch0/lora/command",
            json.dumps(command_payload).encode("utf-8"),
        )

    reader = FakeReader([("call", route_command)], stream=stream)

    cli.run_receiver(
        args(),
        shutdown=FakeShutdown(),
        telemetry=telemetry,
        publisher_factory=publisher_factory,
        reader_factory=lambda _args: reader,
    )

    assert captured["route_result"].accepted is True
    assert json.loads(stream.writes[0].rstrip(b"\n").decode("utf-8")) == {
        "t": "cmd",
        "c": "rr",
        "n": "sensor-zone1-ch0",
        "mid": "pi-20260821T153000Z-abc123",
        "sq": 1,
    }
    assert stream.flushes == 1


def test_extracts_command_message_id_from_publish_request():
    request = cli.build_lora_frame_publish_request(compact_lora_state_frame(mid="pi-001"))

    assert cli.command_message_id_from_publish_request(request) == "pi-001"


def test_runtime_closes_publisher_when_reader_factory_fails():
    logger_events = []
    telemetry = LoRaReceiverTelemetry(logger=lambda *args, **kwargs: logger_events.append((args, kwargs)))
    publisher = FakePublisher()

    def fail_reader_factory(_args):
        raise RuntimeError("serial setup failed")

    try:
        cli.run_receiver(
            args(),
            shutdown=FakeShutdown(),
            telemetry=telemetry,
            publisher_factory=lambda _args, _telemetry, _command_route_handler: publisher,
            reader_factory=fail_reader_factory,
        )
    except RuntimeError as exc:
        assert str(exc) == "serial setup failed"
    else:
        raise AssertionError("expected reader factory failure")

    assert publisher.closed is True
    assert logger_events[-1][0][1] == "shutdown"
