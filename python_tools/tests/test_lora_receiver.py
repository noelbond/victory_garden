import json
from dataclasses import asdict

import pytest
from pydantic import ValidationError

import watering.lora_receiver as lora_receiver
from watering.lora_receiver import (
    ExactFrameDeduplicatingPublisher,
    InvalidCompactLoRaStateFrameError,
    InvalidLoRaCommandAckFrameError,
    InvalidLoRaFrameError,
    InvalidNodeStateFrameError,
    LoRaReceiverCounters,
    LoRaReceiverTelemetry,
    MqttConnectionSettings,
    MqttConnectionEvent,
    NodeStatePublishRequest,
    NodeStatePublishResult,
    PahoNodeStatePublisher,
    ShutdownController,
    build_paho_node_state_publisher,
    build_compact_lora_state_publish_request,
    build_lora_command_ack_publish_request,
    build_lora_frame_publish_request,
    build_node_state_publish_request,
    canonical_node_state_topic,
    mqtt_connection_settings_from_env,
    parse_json_frame,
    validate_compact_lora_state,
    validate_sensor_reading,
)
from watering.lora_transmitter import LoRaCommandRouteResult
from watering.serial_frames import SerialFrameDecodeError, SerialFrameDecoder


def node_state_payload(**overrides):
    payload = {
        "schema_version": "node-state/v1",
        "zone_id": "zone1",
        "node_id": "sensor-zone1-ch0",
        "moisture_raw": 1820,
    }
    payload.update(overrides)
    return payload


def lora_command_ack_payload(**overrides):
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
    return payload


def compact_lora_state_payload(**overrides):
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
    return payload


class TestSerialFrameDecoder:
    def test_reassembles_newline_delimited_frames_across_chunks(self):
        decoder = SerialFrameDecoder()

        assert decoder.feed(b'{"node_id":"sensor').frames == []
        result = decoder.feed(b'-1"}\n{"node_id":"sensor-2"}\r\npart')
        assert result.frames == [
            b'{"node_id":"sensor-1"}',
            b'{"node_id":"sensor-2"}',
        ]
        assert result.errors == []
        assert decoder.feed(b"ial\n").frames == [b"partial"]

    def test_rejects_oversized_partial_frame_and_recovers_after_newline(self):
        decoder = SerialFrameDecoder(max_frame_size=5)

        result = decoder.feed(b"abcdef")

        assert result.frames == []
        assert result.errors == [
            SerialFrameDecodeError(
                reason="frame_too_large",
                message="serial frame exceeds max_frame_size",
            )
        ]

        result = decoder.feed(b"still bad\nok\n")
        assert result.frames == [b"ok"]
        assert result.errors == []

    def test_rejects_oversized_completed_frame_and_recovers_next_frame(self):
        decoder = SerialFrameDecoder(max_frame_size=5)

        result = decoder.feed(b"abcdef\nok\n")

        assert result.frames == [b"ok"]
        assert result.errors == [
            SerialFrameDecodeError(
                reason="frame_too_large",
                message="serial frame exceeds max_frame_size",
            )
        ]

    def test_accepts_crlf_frame_at_max_content_size(self):
        decoder = SerialFrameDecoder(max_frame_size=5)

        result = decoder.feed(b"12345\r\n")

        assert result.frames == [b"12345"]
        assert result.errors == []


class TestParseJsonFrame:
    def test_parses_utf8_json_object(self):
        payload = node_state_payload()

        assert parse_json_frame(json.dumps(payload).encode("utf-8")) == payload

    def test_rejects_invalid_utf8_malformed_json_and_non_object_json(self):
        with pytest.raises(UnicodeDecodeError):
            parse_json_frame(b"\xff")

        with pytest.raises(json.JSONDecodeError):
            parse_json_frame(b"{")

        with pytest.raises(ValueError, match="expected JSON object"):
            parse_json_frame(b"[]")


class TestValidateSensorReading:
    def test_validates_payload_through_sensor_reading(self):
        reading = validate_sensor_reading(node_state_payload(moisture_percent=31.4))

        assert reading.schema_version == "node-state/v1"
        assert reading.zone_id == "zone1"
        assert reading.node_id == "sensor-zone1-ch0"
        assert reading.moisture_percent == 31.4

    def test_requires_node_state_schema_version(self):
        with pytest.raises(ValueError, match="schema_version must be node-state/v1"):
            validate_sensor_reading(node_state_payload(schema_version="other/v1"))

        with pytest.raises(ValueError, match="schema_version must be node-state/v1"):
            validate_sensor_reading(node_state_payload(schema_version=None))

    def test_preserves_sensor_reading_validation(self):
        with pytest.raises(ValidationError):
            validate_sensor_reading(node_state_payload(moisture_percent=101.0))

    @pytest.mark.parametrize(
        ("field_name", "bad_value"),
        [
            ("zone_id", "zone/1"),
            ("zone_id", "zone+1"),
            ("node_id", "node#1"),
            ("node_id", "node 1"),
        ],
    )
    def test_requires_mqtt_safe_zone_and_node_ids(self, field_name, bad_value):
        with pytest.raises(ValueError, match=f"{field_name} must be MQTT-safe"):
            validate_sensor_reading(node_state_payload(**{field_name: bad_value}))


def test_derives_canonical_node_state_topic():
    reading = validate_sensor_reading(node_state_payload())

    assert canonical_node_state_topic(reading) == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"


class TestValidateCompactLoRaState:
    def test_expands_compact_state_to_canonical_node_state_payload(self):
        payload = validate_compact_lora_state(compact_lora_state_payload())

        assert payload["schema_version"] == "node-state/v1"
        assert payload["zone_id"] == "zone1"
        assert payload["node_id"] == "sensor-zone1-ch0"
        assert payload["moisture_raw"] == 2345
        assert payload["moisture_percent"] == 55
        assert payload["uptime_seconds"] == 123
        assert payload["health"] == "ok"
        assert payload["last_error"] == "none"
        assert payload["publish_reason"] == "request_reading"
        assert payload["command_message_id"] == "pi-001"
        assert "mid" not in payload

    def test_expands_optional_compact_state_sequence(self):
        payload = validate_compact_lora_state(compact_lora_state_payload(sq=42))

        assert payload["lora_sequence"] == 42
        assert "sq" not in payload

    @pytest.mark.parametrize(
        ("field_name", "bad_value", "expected"),
        [
            ("t", "other", "t must be state"),
            ("z", "zone/1", "z must be MQTT-safe"),
            ("n", "node 1", "n must be MQTT-safe"),
            ("mid", "pi/001", "mid must be MQTT-safe"),
            ("mr", -1, "greater than or equal to 0"),
            ("mp", 101, "less than or equal to 100"),
            ("up", -1, "greater than or equal to 0"),
            ("sq", 0, "sq must be greater than or equal to 1"),
            ("sq", "1", "sq must be an integer"),
        ],
    )
    def test_rejects_invalid_compact_state_fields(self, field_name, bad_value, expected):
        with pytest.raises(ValueError, match=expected):
            validate_compact_lora_state(compact_lora_state_payload(**{field_name: bad_value}))

    def test_requires_compact_state_fields(self):
        payload = compact_lora_state_payload()
        del payload["mid"]

        with pytest.raises(ValueError, match="missing compact LoRa state field: mid"):
            validate_compact_lora_state(payload)


class TestBuildNodeStatePublishRequest:
    def test_builds_publish_request_from_valid_frame(self):
        frame = json.dumps(node_state_payload()).encode("utf-8")

        request = build_node_state_publish_request(frame)

        assert request.topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
        assert request.payload == frame

    def test_wraps_invalid_frame_errors_with_reason(self):
        with pytest.raises(InvalidNodeStateFrameError) as exc_info:
            build_node_state_publish_request(b"{")

        assert exc_info.value.reason == "JSONDecodeError"
        assert isinstance(exc_info.value.__cause__, json.JSONDecodeError)


class TestBuildCompactLoRaStatePublishRequest:
    def test_builds_canonical_node_state_publish_request_from_compact_frame(self):
        frame = json.dumps(compact_lora_state_payload(), separators=(",", ":")).encode("utf-8")

        request = build_compact_lora_state_publish_request(frame)
        payload = json.loads(request.payload.decode("utf-8"))

        assert request.topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
        assert payload["schema_version"] == "node-state/v1"
        assert payload["zone_id"] == "zone1"
        assert payload["node_id"] == "sensor-zone1-ch0"
        assert payload["moisture_raw"] == 2345
        assert payload["moisture_percent"] == 55
        assert payload["uptime_seconds"] == 123
        assert payload["publish_reason"] == "request_reading"
        assert payload["command_message_id"] == "pi-001"
        assert request.payload != frame
        assert request.dedup_key == frame

    def test_builds_publish_request_with_lora_sequence(self):
        frame = json.dumps(compact_lora_state_payload(sq=42), separators=(",", ":")).encode("utf-8")

        request = build_compact_lora_state_publish_request(frame)
        payload = json.loads(request.payload.decode("utf-8"))

        assert payload["lora_sequence"] == 42

    def test_wraps_invalid_compact_state_errors_with_reason(self):
        frame = json.dumps(compact_lora_state_payload(n="node 1"), separators=(",", ":")).encode("utf-8")

        with pytest.raises(InvalidCompactLoRaStateFrameError) as exc_info:
            build_compact_lora_state_publish_request(frame)

        assert exc_info.value.reason == "ValueError"
        assert "n must be MQTT-safe" in str(exc_info.value)


class TestBuildLoRaCommandAckPublishRequest:
    def test_builds_publish_request_from_valid_ack_frame(self):
        frame = json.dumps(lora_command_ack_payload(), separators=(",", ":")).encode("utf-8")

        request = build_lora_command_ack_publish_request(frame)

        assert request.topic == "greenhouse/nodes/sensor-zone1-ch0/lora/command_ack"
        assert request.payload == frame

    def test_rejects_ack_targeted_elsewhere(self):
        frame = json.dumps(lora_command_ack_payload(target="other-gateway"), separators=(",", ":")).encode("utf-8")

        with pytest.raises(InvalidLoRaCommandAckFrameError) as exc_info:
            build_lora_command_ack_publish_request(frame)

        assert exc_info.value.reason == "ValueError"
        assert "target must be pi-gateway" in str(exc_info.value)


class TestBuildLoRaFramePublishRequest:
    def test_dispatches_node_state_frame(self):
        frame = json.dumps(node_state_payload(), separators=(",", ":")).encode("utf-8")

        request = build_lora_frame_publish_request(frame)

        assert request.topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
        assert request.payload == frame

    def test_dispatches_lora_command_ack_frame(self):
        frame = json.dumps(lora_command_ack_payload(), separators=(",", ":")).encode("utf-8")

        request = build_lora_frame_publish_request(frame)

        assert request.topic == "greenhouse/nodes/sensor-zone1-ch0/lora/command_ack"
        assert request.payload == frame

    def test_dispatches_compact_lora_state_frame(self):
        frame = json.dumps(compact_lora_state_payload(), separators=(",", ":")).encode("utf-8")

        request = build_lora_frame_publish_request(frame)
        payload = json.loads(request.payload.decode("utf-8"))

        assert request.topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
        assert payload["schema_version"] == "node-state/v1"
        assert payload["publish_reason"] == "request_reading"
        assert request.payload != frame

    def test_rejects_unknown_schema_version(self):
        frame = json.dumps({"schema_version": "other/v1"}).encode("utf-8")

        with pytest.raises(InvalidLoRaFrameError) as exc_info:
            build_lora_frame_publish_request(frame)

        assert exc_info.value.reason == "unsupported_schema_version"

    def test_wraps_invalid_ack_errors(self):
        frame = json.dumps(lora_command_ack_payload(error="not allowed"), separators=(",", ":")).encode("utf-8")

        with pytest.raises(InvalidLoRaCommandAckFrameError) as exc_info:
            build_lora_frame_publish_request(frame)

        assert exc_info.value.reason == "ValidationError"


class FakePublishInfo:
    def __init__(self, rc):
        self.rc = rc


class FakeMqttClient:
    def __init__(self, publish_rc=0):
        self.publish_rc = publish_rc
        self.published = []
        self.max_queued_messages = None
        self.username_password = None
        self.connected = None
        self.loop_started = False
        self.loop_stopped = False
        self.disconnected = False
        self.on_connect = None
        self.on_disconnect = None
        self.on_message = None
        self.subscribed = []

    def max_queued_messages_set(self, value):
        self.max_queued_messages = value

    def username_pw_set(self, username, password=None):
        self.username_password = (username, password)

    def connect(self, host, port, keepalive):
        self.connected = (host, port, keepalive)

    def loop_start(self):
        self.loop_started = True

    def loop_stop(self):
        self.loop_stopped = True

    def disconnect(self):
        self.disconnected = True

    def publish(self, *args, **kwargs):
        self.published.append((args, kwargs))
        return FakePublishInfo(self.publish_rc)

    def subscribe(self, *args, **kwargs):
        self.subscribed.append((args, kwargs))
        return (lora_receiver.mqtt.MQTT_ERR_SUCCESS, 1)


class FakePublisher:
    def __init__(self, *, accepted=True):
        self.accepted = accepted
        self.requests = []
        self.closed = False

    def publish_node_state(self, request):
        self.requests.append(request)
        return NodeStatePublishResult(accepted=self.accepted)

    def close(self):
        self.closed = True


class FakeSignalModule:
    def __init__(self):
        self.handlers = {}

    def signal(self, sig, handler):
        self.handlers[sig] = handler


class FakeSerialStream:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.closed = False
        self.read_sizes = []

    def read(self, size=1):
        self.read_sizes.append(size)
        return self.chunks.pop(0) if self.chunks else b""

    def close(self):
        self.closed = True


class FakeResettableSerialStream(FakeSerialStream):
    def __init__(self, chunks, events):
        super().__init__(chunks)
        self.events = events

    def reset_input_buffer(self):
        self.events.append("reset_input_buffer")


class FakeLogger:
    def __init__(self):
        self.events = []

    def __call__(self, component, event, level="info", **fields):
        self.events.append(
            {
                "component": component,
                "event": event,
                "level": level,
                **fields,
            }
        )


class TestShutdownController:
    def test_tracks_stop_request(self):
        shutdown = ShutdownController()

        assert shutdown.should_stop() is False
        shutdown.request_stop()
        assert shutdown.should_stop() is True

    def test_installs_signal_handlers_that_request_stop(self):
        shutdown = ShutdownController()
        signal_module = FakeSignalModule()

        shutdown.install_signal_handlers(
            signals=(lora_receiver.signal.SIGINT, lora_receiver.signal.SIGTERM),
            signal_module=signal_module,
        )
        signal_module.handlers[lora_receiver.signal.SIGTERM](lora_receiver.signal.SIGTERM, None)

        assert set(signal_module.handlers) == {
            lora_receiver.signal.SIGINT,
            lora_receiver.signal.SIGTERM,
        }
        assert shutdown.should_stop() is True

    def test_serial_reader_stops_when_shutdown_is_requested(self):
        serial_stream = FakeSerialStream([b"one\n", b"two\n"])
        shutdown = ShutdownController()
        reader = lora_receiver.LoRaSerialReader(serial_stream, read_size=8)
        frames = []

        def on_frame(frame):
            frames.append(frame)
            shutdown.request_stop()

        reader.run(on_frame=on_frame, should_stop=shutdown.should_stop)
        reader.close()

        assert frames == [b"one"]
        assert serial_stream.closed is True
        assert serial_stream.read_sizes == [8]

    def test_reconnecting_reader_resets_input_buffer_before_ready_callbacks(self):
        events = []
        serial_stream = FakeResettableSerialStream([], events)
        stop_checks = 0
        reader = lora_receiver.ReconnectingLoRaSerialReader(
            lora_receiver.SerialConnectionSettings(
                port="/dev/fake-lora",
                read_size=8,
                reconnect_delay_seconds=0,
            ),
            port_factory=lambda _settings: serial_stream,
            sleep=lambda _seconds: None,
        )

        def should_stop():
            nonlocal stop_checks
            stop_checks += 1
            return stop_checks > 1

        reader.run(
            on_frame=lambda _frame: None,
            should_stop=should_stop,
            on_serial_connected=lambda: events.append("serial_connected"),
            on_serial_ready=lambda _port: events.append("serial_ready"),
        )

        assert events == ["reset_input_buffer", "serial_connected", "serial_ready"]
        assert serial_stream.closed is True


class TestLoRaReceiverTelemetry:
    def test_logs_serial_and_mqtt_connection_events_with_counters(self):
        logger = FakeLogger()
        telemetry = LoRaReceiverTelemetry(logger=logger)

        telemetry.serial_connected()
        telemetry.serial_disconnected(RuntimeError("usb gone"))
        telemetry.mqtt_connected(MqttConnectionEvent(connected=True, reason_code=0))
        telemetry.mqtt_disconnected(
            MqttConnectionEvent(
                connected=False,
                reason_code=7,
                disconnect_flags="flags",
            )
        )

        assert telemetry.counters.serial_connects == 1
        assert telemetry.counters.serial_disconnects == 1
        assert telemetry.counters.mqtt_connects == 1
        assert telemetry.counters.mqtt_disconnects == 1
        assert logger.events == [
            {
                "component": "lora_receiver",
                "event": "serial_connected",
                "level": "info",
                "serial_connects": 1,
            },
            {
                "component": "lora_receiver",
                "event": "serial_disconnected",
                "level": "warning",
                "error": "usb gone",
                "serial_disconnects": 1,
            },
            {
                "component": "lora_receiver",
                "event": "mqtt_connected",
                "level": "info",
                "reason_code": 0,
                "mqtt_connects": 1,
            },
            {
                "component": "lora_receiver",
                "event": "mqtt_disconnected",
                "level": "warning",
                "reason_code": 7,
                "disconnect_flags": "flags",
                "mqtt_disconnects": 1,
            },
        ]

    def test_logs_frame_decode_validation_publish_and_shutdown_counters(self):
        logger = FakeLogger()
        counters = LoRaReceiverCounters()
        telemetry = LoRaReceiverTelemetry(counters=counters, logger=logger)
        request = NodeStatePublishRequest("greenhouse/zones/zone1/nodes/node1/state", b'{"ok":true}')

        telemetry.frame_received(request.payload)
        telemetry.decode_error(
            SerialFrameDecodeError(
                reason="frame_too_large",
                message="serial frame exceeds max_frame_size",
            )
        )
        telemetry.invalid_frame(reason="invalid_json", error=ValueError("bad json"))
        telemetry.publish_result(request, NodeStatePublishResult(accepted=True))
        telemetry.publish_result(
            request,
            NodeStatePublishResult(accepted=False, reason="duplicate_frame"),
        )
        telemetry.publish_result(
            request,
            NodeStatePublishResult(accepted=False, reason="mqtt_disconnected"),
        )
        telemetry.shutdown()

        assert counters.frames_received == 1
        assert counters.frame_bytes_received == len(request.payload)
        assert counters.decoder_errors == 1
        assert counters.invalid_frames == 1
        assert counters.frames_published == 1
        assert counters.frames_dropped == 2
        assert [event["event"] for event in logger.events] == [
            "frame_received",
            "serial_decode_error",
            "invalid_frame",
            "frame_published",
            "frame_dropped",
            "frame_dropped",
            "shutdown",
        ]
        assert logger.events[4]["level"] == "info"
        assert logger.events[4]["reason"] == "duplicate_frame"
        assert logger.events[5]["level"] == "warning"
        assert logger.events[5]["reason"] == "mqtt_disconnected"
        assert logger.events[-1]["counters"] == asdict(counters)

    def test_logs_lora_command_routing_counters(self):
        logger = FakeLogger()
        counters = LoRaReceiverCounters()
        telemetry = LoRaReceiverTelemetry(counters=counters, logger=logger)

        telemetry.lora_command_received("greenhouse/nodes/node1/lora/command")
        telemetry.lora_command_route_result(
            LoRaCommandRouteResult(
                accepted=True,
                topic="greenhouse/nodes/node1/lora/command",
                target_node_id="node1",
                message_id="msg-1",
                frame_size=42,
            )
        )
        telemetry.lora_command_route_result(
            LoRaCommandRouteResult(
                accepted=False,
                topic="greenhouse/nodes/node1/lora/command",
                reason="serial_disconnected",
            )
        )

        assert counters.lora_commands_received == 1
        assert counters.lora_commands_routed == 1
        assert counters.lora_commands_dropped == 1
        assert [event["event"] for event in logger.events] == [
            "lora_command_received",
            "lora_command_routed",
            "lora_command_dropped",
        ]
        assert logger.events[1]["message_id"] == "msg-1"
        assert logger.events[2]["reason"] == "serial_disconnected"

    def test_accepts_custom_component_name(self):
        logger = FakeLogger()

        LoRaReceiverTelemetry(logger=logger, component="custom_lora").serial_connected()

        assert logger.events[0]["component"] == "custom_lora"


class TestPahoNodeStatePublisher:
    def test_publishes_qos1_retained_node_state_with_exact_payload(self):
        client = FakeMqttClient()
        publisher = PahoNodeStatePublisher(client, connected=True)
        request = NodeStatePublishRequest("greenhouse/zones/zone1/nodes/node1/state", b'{"ok":true}')

        result = publisher.publish_node_state(request)

        assert result == NodeStatePublishResult(accepted=True)
        assert client.published == [
            (
                ("greenhouse/zones/zone1/nodes/node1/state", b'{"ok":true}'),
                {"qos": 1, "retain": True},
            )
        ]

    def test_reports_full_paho_queue_without_raising(self):
        client = FakeMqttClient(publish_rc=lora_receiver.mqtt.MQTT_ERR_QUEUE_SIZE)

        result = PahoNodeStatePublisher(client, connected=True).publish_node_state(
            NodeStatePublishRequest("topic", b"payload")
        )

        assert result == NodeStatePublishResult(accepted=False, reason="mqtt_queue_full")

    def test_reports_other_paho_publish_errors_without_raising(self):
        client = FakeMqttClient(publish_rc=4)

        result = PahoNodeStatePublisher(client, connected=True).publish_node_state(
            NodeStatePublishRequest("topic", b"payload")
        )

        assert result == NodeStatePublishResult(accepted=False, reason="mqtt_publish_error:4")

    def test_reports_disconnected_without_publishing(self):
        client = FakeMqttClient()

        result = PahoNodeStatePublisher(client).publish_node_state(
            NodeStatePublishRequest("topic", b"payload")
        )

        assert result == NodeStatePublishResult(accepted=False, reason="mqtt_disconnected")
        assert client.published == []

    def test_tracks_manual_mqtt_connection_state(self):
        publisher = PahoNodeStatePublisher(FakeMqttClient())

        assert publisher.connected is False
        publisher.mark_connected()
        assert publisher.connected is True
        publisher.mark_disconnected()
        assert publisher.connected is False

    def test_stops_loop_and_disconnects_on_close(self):
        client = FakeMqttClient()

        PahoNodeStatePublisher(client).close()

        assert client.loop_stopped is True
        assert client.disconnected is True


class TestMqttPublisherBuilder:
    def test_reads_existing_mqtt_environment_variable_names(self):
        settings = mqtt_connection_settings_from_env(
            {
                "MQTT_HOST": "mqtt.local",
                "MQTT_PORT": "1884",
                "MQTT_USERNAME": "victory_garden",
                "MQTT_PASSWORD": "secret",
            }
        )

        assert settings == MqttConnectionSettings(
            host="mqtt.local",
            port=1884,
            username="victory_garden",
            password="secret",
        )

    def test_reports_malformed_mqtt_port_with_clear_error(self):
        with pytest.raises(ValueError, match="MQTT_PORT must be an integer, got 'bad'"):
            mqtt_connection_settings_from_env({"MQTT_PORT": "bad"})

    def test_builds_configured_paho_publisher_with_fake_client(self, monkeypatch):
        clients = []
        connected_events = []
        disconnected_events = []

        def fake_client_factory(_callback_api_version):
            client = FakeMqttClient()
            clients.append(client)
            return client

        monkeypatch.setattr(lora_receiver.mqtt, "Client", fake_client_factory)

        publisher = build_paho_node_state_publisher(
            MqttConnectionSettings(
                host="mqtt.local",
                port=1884,
                username="victory_garden",
                password="secret",
                keepalive_seconds=30,
                max_queued_messages=7,
            ),
            on_mqtt_connected=connected_events.append,
            on_mqtt_disconnected=disconnected_events.append,
        )

        assert isinstance(publisher, PahoNodeStatePublisher)
        assert publisher.connected is False
        assert len(clients) == 1
        assert clients[0].max_queued_messages == 7
        assert clients[0].username_password == ("victory_garden", "secret")
        assert clients[0].connected == ("mqtt.local", 1884, 30)
        assert clients[0].loop_started is True
        assert callable(clients[0].on_connect)
        assert callable(clients[0].on_disconnect)

        clients[0].on_connect(clients[0], None, None, 0)
        assert publisher.connected is True
        assert connected_events == [MqttConnectionEvent(connected=True, reason_code=0)]

        clients[0].on_disconnect(clients[0], None, "flags", 7)
        assert publisher.connected is False
        assert disconnected_events == [
            MqttConnectionEvent(
                connected=False,
                reason_code=7,
                disconnect_flags="flags",
            )
        ]

    def test_subscribes_and_dispatches_lora_commands_when_handler_is_configured(self, monkeypatch):
        clients = []
        received_topics = []
        route_results = []
        routed_messages = []

        def fake_client_factory(_callback_api_version):
            client = FakeMqttClient()
            clients.append(client)
            return client

        class FakeMessage:
            topic = "greenhouse/nodes/sensor-zone1-ch0/lora/command"
            payload = b'{"schema_version":"lora-command/v1"}'

        def route_message(topic, payload):
            routed_messages.append((topic, payload))
            return LoRaCommandRouteResult(
                accepted=True,
                topic=topic,
                target_node_id="sensor-zone1-ch0",
                message_id="msg-1",
                frame_size=42,
            )

        monkeypatch.setattr(lora_receiver.mqtt, "Client", fake_client_factory)

        build_paho_node_state_publisher(
            MqttConnectionSettings(),
            on_lora_command_message=route_message,
            on_lora_command_received=received_topics.append,
            on_lora_command_route_result=route_results.append,
        )

        clients[0].on_connect(clients[0], None, None, 0)
        clients[0].on_message(clients[0], None, FakeMessage())

        assert clients[0].subscribed == [
            (("greenhouse/nodes/+/lora/command",), {"qos": 1}),
        ]
        assert received_topics == ["greenhouse/nodes/sensor-zone1-ch0/lora/command"]
        assert routed_messages == [
            ("greenhouse/nodes/sensor-zone1-ch0/lora/command", b'{"schema_version":"lora-command/v1"}'),
        ]
        assert route_results == [
            LoRaCommandRouteResult(
                accepted=True,
                topic="greenhouse/nodes/sensor-zone1-ch0/lora/command",
                target_node_id="sensor-zone1-ch0",
                message_id="msg-1",
                frame_size=42,
            )
        ]

    def test_failed_mqtt_connect_keeps_publisher_disconnected(self, monkeypatch):
        clients = []
        connected_events = []
        disconnected_events = []

        def fake_client_factory(_callback_api_version):
            client = FakeMqttClient()
            clients.append(client)
            return client

        monkeypatch.setattr(lora_receiver.mqtt, "Client", fake_client_factory)

        publisher = build_paho_node_state_publisher(
            MqttConnectionSettings(),
            on_mqtt_connected=connected_events.append,
            on_mqtt_disconnected=disconnected_events.append,
        )

        clients[0].on_connect(clients[0], None, None, 5)

        assert publisher.connected is False
        assert connected_events == []
        assert disconnected_events == [MqttConnectionEvent(connected=False, reason_code=5)]

    def test_rejects_invalid_queue_bound(self):
        with pytest.raises(ValueError, match="max_queued_messages"):
            build_paho_node_state_publisher(MqttConnectionSettings(max_queued_messages=0))


class TestExactFrameDeduplicatingPublisher:
    def test_suppresses_exact_duplicate_payloads(self):
        inner = FakePublisher()
        publisher = ExactFrameDeduplicatingPublisher(inner)
        request = NodeStatePublishRequest("topic", b'{"a":1}')

        assert publisher.publish_node_state(request) == NodeStatePublishResult(accepted=True)
        assert publisher.publish_node_state(request) == NodeStatePublishResult(
            accepted=False,
            reason="duplicate_frame",
        )
        assert inner.requests == [request]

    def test_does_not_deduplicate_when_inner_publish_is_rejected(self):
        inner = FakePublisher(accepted=False)
        publisher = ExactFrameDeduplicatingPublisher(inner)
        request = NodeStatePublishRequest("topic", b'{"a":1}')

        assert publisher.publish_node_state(request) == NodeStatePublishResult(accepted=False)
        assert publisher.publish_node_state(request) == NodeStatePublishResult(accepted=False)
        assert inner.requests == [request, request]

    def test_forgets_old_frames_after_bounded_recent_window(self):
        inner = FakePublisher()
        publisher = ExactFrameDeduplicatingPublisher(inner, max_recent_frames=2)

        for payload in [b"a", b"b", b"c", b"a"]:
            assert publisher.publish_node_state(NodeStatePublishRequest("topic", payload)).accepted

        assert [request.payload for request in inner.requests] == [b"a", b"b", b"c", b"a"]

    def test_uses_dedup_key_when_request_payload_is_translated(self):
        inner = FakePublisher()
        publisher = ExactFrameDeduplicatingPublisher(inner)

        first = NodeStatePublishRequest(
            topic="greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state",
            payload=b'{"schema_version":"node-state/v1","timestamp":"one"}',
            dedup_key=b'{"t":"state","mid":"pi-001"}',
        )
        translated_duplicate = NodeStatePublishRequest(
            topic="greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state",
            payload=b'{"schema_version":"node-state/v1","timestamp":"two"}',
            dedup_key=b'{"t":"state","mid":"pi-001"}',
        )

        assert publisher.publish_node_state(first) == NodeStatePublishResult(accepted=True)
        assert publisher.publish_node_state(translated_duplicate) == NodeStatePublishResult(
            accepted=False,
            reason="duplicate_frame",
        )
        assert inner.requests == [first]

    def test_forwards_close_to_inner_publisher(self):
        inner = FakePublisher()

        ExactFrameDeduplicatingPublisher(inner).close()

        assert inner.closed is True
