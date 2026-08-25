"""LoRa serial receive framing and inbound gateway frame validation."""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import time
import threading
from types import FrameType
from typing import Any, Callable, Mapping, Protocol

import paho.mqtt.client as mqtt
import serial

from watering.controller_mqtt import mqtt_reason_code_value
from watering.state_store import atomic_write_text
from watering.lora_messages import (
    LORA_COMMAND_ACK_SCHEMA_VERSION,
    LORA_COMMAND_ACK_TARGET,
    LORA_COMMAND_TOPIC_FILTER,
    canonical_lora_command_ack_topic,
    validate_lora_command_ack,
)
from watering.lora_transmitter import LoRaCommandRouteResult
from watering.schemas import SensorReading
from watering.serial_frames import SerialFrameDecodeError, SerialFrameDecoder, SerialFrameWriteStream
from watering.structured_logging import log_event

NODE_STATE_SCHEMA_VERSION = "node-state/v1"
MQTT_SAFE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")


def utc_iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class NodeStatePublishRequest:
    topic: str
    payload: bytes
    dedup_key: bytes | None = None


@dataclass(frozen=True)
class NodeStatePublishResult:
    accepted: bool
    reason: str | None = None


class InvalidLoRaFrameError(ValueError):
    def __init__(self, *, reason: str, message: str) -> None:
        super().__init__(message)
        self.reason = reason


class InvalidNodeStateFrameError(InvalidLoRaFrameError):
    pass


class InvalidCompactLoRaStateFrameError(InvalidLoRaFrameError):
    pass


class InvalidLoRaCommandAckFrameError(InvalidLoRaFrameError):
    pass


@dataclass(frozen=True)
class MqttConnectionSettings:
    host: str = "127.0.0.1"
    port: int = 1883
    username: str | None = None
    password: str | None = None
    keepalive_seconds: int = 60
    max_queued_messages: int = 100


@dataclass(frozen=True)
class MqttConnectionEvent:
    connected: bool
    reason_code: int | str | None = None
    disconnect_flags: str | None = None


@dataclass(frozen=True)
class SerialConnectionSettings:
    port: str
    baudrate: int = 9600
    timeout_seconds: float = 1.0
    read_size: int = 256
    reconnect_delay_seconds: float = 2.0

    def __post_init__(self) -> None:
        if self.baudrate < 1:
            raise ValueError("baudrate must be at least 1")
        if self.timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be greater than 0")
        if self.read_size < 1:
            raise ValueError("read_size must be at least 1")
        if self.reconnect_delay_seconds < 0:
            raise ValueError("reconnect_delay_seconds must be at least 0")


@dataclass
class LoRaReceiverCounters:
    serial_connects: int = 0
    serial_disconnects: int = 0
    mqtt_connects: int = 0
    mqtt_disconnects: int = 0
    frames_received: int = 0
    frame_bytes_received: int = 0
    decoder_errors: int = 0
    invalid_frames: int = 0
    frames_published: int = 0
    frames_dropped: int = 0
    lora_commands_received: int = 0
    lora_commands_routed: int = 0
    lora_commands_dropped: int = 0


@dataclass(frozen=True)
class LoRaReceiverStatusWriter:
    path: Path

    def write(self, status: Mapping[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write_text(self.path, json.dumps(status, indent=2, sort_keys=True))


class NodeStatePublisher(Protocol):
    def publish_node_state(self, request: NodeStatePublishRequest) -> NodeStatePublishResult:
        """Publish one validated node-state payload."""

    def close(self) -> None:
        """Release publisher resources."""


class SerialByteStream(Protocol):
    def read(self, size: int = 1) -> bytes:
        """Read bytes from the serial stream."""

    def close(self) -> None:
        """Close the serial stream."""


class SerialGatewayStream(SerialByteStream, SerialFrameWriteStream, Protocol):
    """Serial stream used for both inbound reads and outbound command writes."""


class ShutdownController:
    def __init__(self) -> None:
        self._stop_requested = threading.Event()

    def request_stop(self) -> None:
        self._stop_requested.set()

    def should_stop(self) -> bool:
        return self._stop_requested.is_set()

    def install_signal_handlers(
        self,
        *,
        signals: tuple[signal.Signals, ...] = (signal.SIGINT, signal.SIGTERM),
        signal_module=signal,
    ) -> None:
        for sig in signals:
            signal_module.signal(sig, self._handle_signal)

    def _handle_signal(self, _signum: int, _frame: FrameType | None) -> None:
        self.request_stop()


class LoRaReceiverTelemetry:
    def __init__(
        self,
        *,
        counters: LoRaReceiverCounters | None = None,
        logger: Callable[..., None] = log_event,
        component: str = "lora_receiver",
        status_writer: LoRaReceiverStatusWriter | None = None,
        serial_port: str | None = None,
        clock: Callable[[], str] = utc_iso_now,
        status_heartbeat_seconds: float = 30.0,
        monotonic_clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if status_heartbeat_seconds < 0:
            raise ValueError("status_heartbeat_seconds must be greater than or equal to 0")

        self.counters = counters or LoRaReceiverCounters()
        self._logger = logger
        self._component = component
        self._status_writer = status_writer
        self._clock = clock
        self._status_heartbeat_seconds = status_heartbeat_seconds
        self._monotonic_clock = monotonic_clock
        self._last_status_write_monotonic: float | None = None
        self._status_lock = threading.Lock()
        self._status: dict[str, Any] = {
            "component": component,
            "status": "starting",
            "mqtt_connected": False,
            "serial_connected": False,
            "serial_port": serial_port,
            "updated_at": self._clock(),
            "last_mqtt_connected_at": None,
            "last_mqtt_disconnected_at": None,
            "last_serial_connected_at": None,
            "last_serial_disconnected_at": None,
            "last_frame_received_at": None,
            "last_frame_published_at": None,
            "last_command_received_at": None,
            "last_command_routed_at": None,
            "last_error": None,
            "counters": asdict(self.counters),
        }
        self._write_status(updated_at=self._status["updated_at"])

    def serial_connected(self) -> None:
        self.counters.serial_connects += 1
        now = self._clock()
        self._status.update(
            serial_connected=True,
            last_serial_connected_at=now,
        )
        self._clear_error_when_connected()
        self._write_status(updated_at=now)
        self._logger(
            self._component,
            "serial_connected",
            serial_connects=self.counters.serial_connects,
        )

    def serial_disconnected(self, error: Exception) -> None:
        self.counters.serial_disconnects += 1
        now = self._clock()
        self._status.update(
            serial_connected=False,
            last_serial_disconnected_at=now,
            last_error=str(error),
        )
        self._write_status(updated_at=now)
        self._logger(
            self._component,
            "serial_disconnected",
            level="warning",
            error=str(error),
            serial_disconnects=self.counters.serial_disconnects,
        )

    def mqtt_connected(self, event: MqttConnectionEvent) -> None:
        self.counters.mqtt_connects += 1
        now = self._clock()
        self._status.update(
            mqtt_connected=True,
            last_mqtt_connected_at=now,
        )
        self._clear_error_when_connected()
        self._write_status(updated_at=now)
        self._logger(
            self._component,
            "mqtt_connected",
            reason_code=event.reason_code,
            mqtt_connects=self.counters.mqtt_connects,
        )

    def mqtt_disconnected(self, event: MqttConnectionEvent) -> None:
        self.counters.mqtt_disconnects += 1
        now = self._clock()
        reason = f"mqtt_disconnected:{event.reason_code}" if event.reason_code is not None else "mqtt_disconnected"
        self._status.update(
            mqtt_connected=False,
            last_mqtt_disconnected_at=now,
            last_error=reason,
        )
        self._write_status(updated_at=now)
        self._logger(
            self._component,
            "mqtt_disconnected",
            level="warning",
            reason_code=event.reason_code,
            disconnect_flags=event.disconnect_flags,
            mqtt_disconnects=self.counters.mqtt_disconnects,
        )

    def frame_received(self, frame: bytes) -> None:
        self.counters.frames_received += 1
        self.counters.frame_bytes_received += len(frame)
        now = self._clock()
        self._write_status(last_frame_received_at=now, updated_at=now)
        self._logger(
            self._component,
            "frame_received",
            frame_size=len(frame),
            frames_received=self.counters.frames_received,
            frame_bytes_received=self.counters.frame_bytes_received,
        )

    def decode_error(self, error: SerialFrameDecodeError) -> None:
        self.counters.decoder_errors += 1
        self._write_status(last_error=f"{error.reason}: {error.message}")
        self._logger(
            self._component,
            "serial_decode_error",
            level="warning",
            reason=error.reason,
            message=error.message,
            decoder_errors=self.counters.decoder_errors,
        )

    def invalid_frame(self, *, reason: str, error: Exception) -> None:
        self.counters.invalid_frames += 1
        self._write_status(last_error=f"{reason}: {error}")
        self._logger(
            self._component,
            "invalid_frame",
            level="warning",
            reason=reason,
            error=str(error),
            invalid_frames=self.counters.invalid_frames,
        )

    def publish_result(self, request: NodeStatePublishRequest, result: NodeStatePublishResult) -> None:
        if result.accepted:
            self.counters.frames_published += 1
            now = self._clock()
            self._write_status(last_frame_published_at=now, updated_at=now)
            self._logger(
                self._component,
                "frame_published",
                topic=request.topic,
                frames_published=self.counters.frames_published,
            )
            return

        self.counters.frames_dropped += 1
        self._write_status(last_error=result.reason)
        self._logger(
            self._component,
            "frame_dropped",
            level="info" if result.reason == "duplicate_frame" else "warning",
            topic=request.topic,
            reason=result.reason,
            frames_dropped=self.counters.frames_dropped,
        )

    def lora_command_received(self, topic: str) -> None:
        self.counters.lora_commands_received += 1
        now = self._clock()
        self._write_status(last_command_received_at=now, updated_at=now)
        self._logger(
            self._component,
            "lora_command_received",
            topic=topic,
            lora_commands_received=self.counters.lora_commands_received,
        )

    def lora_command_route_result(self, result: LoRaCommandRouteResult) -> None:
        if result.accepted:
            self.counters.lora_commands_routed += 1
            now = self._clock()
            self._write_status(last_command_routed_at=now, updated_at=now)
            self._logger(
                self._component,
                "lora_command_routed",
                topic=result.topic,
                target_node_id=result.target_node_id,
                message_id=result.message_id,
                frame_size=result.frame_size,
                lora_commands_routed=self.counters.lora_commands_routed,
            )
            return

        self.counters.lora_commands_dropped += 1
        self._write_status(last_error=result.reason)
        self._logger(
            self._component,
            "lora_command_dropped",
            level="warning",
            topic=result.topic,
            reason=result.reason,
            lora_commands_dropped=self.counters.lora_commands_dropped,
        )

    def shutdown(self) -> None:
        self._write_status(status="stopped")
        self._logger(self._component, "shutdown", counters=asdict(self.counters))

    def heartbeat(self) -> None:
        if self._status_writer is None:
            return

        now = self._monotonic_clock()
        if (
            self._last_status_write_monotonic is not None
            and now - self._last_status_write_monotonic < self._status_heartbeat_seconds
        ):
            return

        self._write_status()

    def _clear_error_when_connected(self) -> None:
        if self._status["mqtt_connected"] and self._status["serial_connected"]:
            self._status["last_error"] = None

    def _derive_status(self) -> str:
        if self._status.get("status") == "stopped":
            return "stopped"
        if self._status["mqtt_connected"] and self._status["serial_connected"]:
            return "connected"
        return "starting" if sum(asdict(self.counters).values()) == 0 else "degraded"

    def _write_status(self, **updates: Any) -> None:
        if self._status_writer is None:
            return

        try:
            with self._status_lock:
                self._status.update(updates)
                self._status["status"] = updates.get("status") or self._derive_status()
                self._status["updated_at"] = updates.get("updated_at") or self._clock()
                self._status["counters"] = asdict(self.counters)
                self._last_status_write_monotonic = self._monotonic_clock()
                self._status_writer.write(dict(self._status))
        except OSError as exc:
            self._logger(
                self._component,
                "status_write_failed",
                level="warning",
                error=str(exc),
            )


class PahoNodeStatePublisher:
    def __init__(self, client: mqtt.Client, *, connected: bool = False) -> None:
        self._client = client
        self._connected = connected

    @property
    def connected(self) -> bool:
        return self._connected

    def publish_node_state(self, request: NodeStatePublishRequest) -> NodeStatePublishResult:
        if not self._connected:
            return NodeStatePublishResult(accepted=False, reason="mqtt_disconnected")

        publish_info = self._client.publish(request.topic, request.payload, qos=1, retain=True)
        if publish_info.rc == mqtt.MQTT_ERR_QUEUE_SIZE:
            return NodeStatePublishResult(accepted=False, reason="mqtt_queue_full")
        if publish_info.rc != mqtt.MQTT_ERR_SUCCESS:
            return NodeStatePublishResult(accepted=False, reason=f"mqtt_publish_error:{publish_info.rc}")

        return NodeStatePublishResult(accepted=True)

    def close(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()

    def mark_connected(self) -> None:
        self._connected = True

    def mark_disconnected(self) -> None:
        self._connected = False


class ExactFrameDeduplicatingPublisher:
    def __init__(self, inner: NodeStatePublisher, *, max_recent_frames: int = 32) -> None:
        if max_recent_frames < 1:
            raise ValueError("max_recent_frames must be at least 1")

        self._inner = inner
        self._max_recent_frames = max_recent_frames
        self._recent_frames: OrderedDict[bytes, None] = OrderedDict()

    def publish_node_state(self, request: NodeStatePublishRequest) -> NodeStatePublishResult:
        dedup_key = request.dedup_key or request.payload
        if dedup_key in self._recent_frames:
            return NodeStatePublishResult(accepted=False, reason="duplicate_frame")

        result = self._inner.publish_node_state(request)
        if result.accepted:
            self._remember_frame(dedup_key)

        return result

    def _remember_frame(self, frame: bytes) -> None:
        self._recent_frames[frame] = None
        self._recent_frames.move_to_end(frame)
        while len(self._recent_frames) > self._max_recent_frames:
            self._recent_frames.popitem(last=False)

    def close(self) -> None:
        close = getattr(self._inner, "close", None)
        if close is not None:
            close()


def mqtt_connection_settings_from_env(
    environ: Mapping[str, str] | None = None,
) -> MqttConnectionSettings:
    source = os.environ if environ is None else environ
    raw_port = source.get("MQTT_PORT", "1883")
    try:
        port = int(raw_port)
    except ValueError as exc:
        raise ValueError(f"MQTT_PORT must be an integer, got {raw_port!r}") from exc

    return MqttConnectionSettings(
        host=source.get("MQTT_HOST", "127.0.0.1"),
        port=port,
        username=source.get("MQTT_USERNAME") or None,
        password=source.get("MQTT_PASSWORD") or None,
    )


def build_paho_node_state_publisher(
    settings: MqttConnectionSettings | None = None,
    *,
    on_mqtt_connected: Callable[[MqttConnectionEvent], None] | None = None,
    on_mqtt_disconnected: Callable[[MqttConnectionEvent], None] | None = None,
    on_lora_command_message: Callable[[str, bytes], LoRaCommandRouteResult] | None = None,
    on_lora_command_received: Callable[[str], None] | None = None,
    on_lora_command_route_result: Callable[[LoRaCommandRouteResult], None] | None = None,
) -> PahoNodeStatePublisher:
    mqtt_settings = settings or mqtt_connection_settings_from_env()
    if mqtt_settings.max_queued_messages < 1:
        raise ValueError("max_queued_messages must be at least 1")

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    publisher = PahoNodeStatePublisher(client)
    client.max_queued_messages_set(mqtt_settings.max_queued_messages)
    if mqtt_settings.username:
        client.username_pw_set(mqtt_settings.username, mqtt_settings.password)

    def on_connect(_client: mqtt.Client, _userdata, _flags, reason_code, _properties=None) -> None:
        reason_code_value = mqtt_reason_code_value(reason_code)
        if reason_code_value == 0:
            publisher.mark_connected()
            if on_lora_command_message is not None:
                _client.subscribe(LORA_COMMAND_TOPIC_FILTER, qos=1)
        else:
            publisher.mark_disconnected()

        if reason_code_value == 0 and on_mqtt_connected is not None:
            on_mqtt_connected(
                MqttConnectionEvent(
                    connected=True,
                    reason_code=reason_code_value,
                )
            )
        elif reason_code_value != 0 and on_mqtt_disconnected is not None:
            on_mqtt_disconnected(
                MqttConnectionEvent(
                    connected=False,
                    reason_code=reason_code_value,
                )
            )

    def on_disconnect(
        _client: mqtt.Client,
        _userdata,
        disconnect_flags,
        reason_code,
        _properties=None,
    ) -> None:
        publisher.mark_disconnected()
        if on_mqtt_disconnected is not None:
            on_mqtt_disconnected(
                MqttConnectionEvent(
                    connected=False,
                    reason_code=mqtt_reason_code_value(reason_code),
                    disconnect_flags=str(disconnect_flags),
                )
            )

    def on_message(_client: mqtt.Client, _userdata, message) -> None:
        if on_lora_command_message is None:
            return

        if on_lora_command_received is not None:
            on_lora_command_received(message.topic)

        result = on_lora_command_message(message.topic, bytes(message.payload))
        if on_lora_command_route_result is not None:
            on_lora_command_route_result(result)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    if on_lora_command_message is not None:
        client.on_message = on_message
    client.connect(mqtt_settings.host, mqtt_settings.port, mqtt_settings.keepalive_seconds)
    client.loop_start()
    return publisher


def build_serial_port(settings: SerialConnectionSettings) -> SerialGatewayStream:
    return serial.Serial(
        port=settings.port,
        baudrate=settings.baudrate,
        timeout=settings.timeout_seconds,
    )


class LoRaSerialReader:
    def __init__(
        self,
        port: SerialGatewayStream,
        *,
        decoder: SerialFrameDecoder | None = None,
        read_size: int = 256,
    ) -> None:
        if read_size < 1:
            raise ValueError("read_size must be at least 1")

        self._port = port
        self._decoder = decoder or SerialFrameDecoder()
        self._read_size = read_size

    def run(
        self,
        *,
        on_frame: Callable[[bytes], None],
        should_stop: Callable[[], bool],
        on_decode_error: Callable[[SerialFrameDecodeError], None] | None = None,
        on_idle: Callable[[], None] | None = None,
    ) -> None:
        while not should_stop():
            chunk = self._port.read(self._read_size)
            if not chunk:
                if on_idle is not None:
                    on_idle()
                continue

            result = self._decoder.feed(chunk)
            for error in result.errors:
                if on_decode_error is not None:
                    on_decode_error(error)
            for frame in result.frames:
                on_frame(frame)

    def close(self) -> None:
        self._port.close()


class ReconnectingLoRaSerialReader:
    def __init__(
        self,
        settings: SerialConnectionSettings,
        *,
        port_factory: Callable[[SerialConnectionSettings], SerialGatewayStream] = build_serial_port,
        decoder: SerialFrameDecoder | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._settings = settings
        self._port_factory = port_factory
        self._decoder = decoder or SerialFrameDecoder()
        self._sleep = sleep

    def run(
        self,
        *,
        on_frame: Callable[[bytes], None],
        should_stop: Callable[[], bool],
        on_decode_error: Callable[[SerialFrameDecodeError], None] | None = None,
        on_serial_connected: Callable[[], None] | None = None,
        on_serial_disconnected: Callable[[Exception], None] | None = None,
        on_serial_ready: Callable[[SerialGatewayStream], Callable[[], None] | None] | None = None,
        on_idle: Callable[[], None] | None = None,
    ) -> None:
        while not should_stop():
            port: SerialGatewayStream | None = None
            serial_ready_cleanup: Callable[[], None] | None = None
            try:
                port = self._port_factory(self._settings)
                self._reset_input_buffer(port)
                if on_serial_connected is not None:
                    on_serial_connected()
                if on_serial_ready is not None:
                    serial_ready_cleanup = on_serial_ready(port)

                reader = LoRaSerialReader(
                    port,
                    decoder=self._decoder,
                    read_size=self._settings.read_size,
                )
                reader.run(
                    on_frame=on_frame,
                    should_stop=should_stop,
                    on_decode_error=on_decode_error,
                    on_idle=on_idle,
                )
                if serial_ready_cleanup is not None:
                    serial_ready_cleanup()
                    serial_ready_cleanup = None
                reader.close()
            except (OSError, serial.SerialException) as exc:
                self._decoder.reset()
                if serial_ready_cleanup is not None:
                    serial_ready_cleanup()
                if port is not None:
                    self._close_port(port)
                if on_serial_disconnected is not None:
                    on_serial_disconnected(exc)
                if not should_stop():
                    self._sleep(self._settings.reconnect_delay_seconds)

    def _close_port(self, port: SerialGatewayStream) -> None:
        try:
            port.close()
        except (OSError, serial.SerialException):
            pass

    def _reset_input_buffer(self, port: SerialGatewayStream) -> None:
        reset_input_buffer = getattr(port, "reset_input_buffer", None)
        if callable(reset_input_buffer):
            reset_input_buffer()


def parse_json_frame(frame: bytes) -> dict[str, Any]:
    payload = json.loads(frame.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("expected JSON object")

    return payload


def validate_sensor_reading(payload: dict[str, Any]) -> SensorReading:
    reading = SensorReading.model_validate(payload)
    if reading.schema_version != NODE_STATE_SCHEMA_VERSION:
        raise ValueError(f"schema_version must be {NODE_STATE_SCHEMA_VERSION}")

    validate_mqtt_safe_id("zone_id", reading.zone_id)
    validate_mqtt_safe_id("node_id", reading.node_id)

    return reading


def validate_mqtt_safe_id(field_name: str, value: str) -> None:
    if not MQTT_SAFE_ID_PATTERN.fullmatch(value):
        raise ValueError(f"{field_name} must be MQTT-safe")


def canonical_node_state_topic(reading: SensorReading) -> str:
    return f"greenhouse/zones/{reading.zone_id}/nodes/{reading.node_id}/state"


def validate_compact_lora_state(payload: dict[str, Any]) -> dict[str, Any]:
    if payload.get("t") != "state":
        raise ValueError("t must be state")

    required_fields = ("z", "n", "mid", "mr", "mp", "up")
    for field_name in required_fields:
        if field_name not in payload:
            raise ValueError(f"missing compact LoRa state field: {field_name}")

    zone_id = payload["z"]
    node_id = payload["n"]
    correlation_id = payload["mid"]
    for field_name, value in (("z", zone_id), ("n", node_id), ("mid", correlation_id)):
        if not isinstance(value, str):
            raise ValueError(f"{field_name} must be a string")
        validate_mqtt_safe_id(field_name, value)

    canonical_payload: dict[str, Any] = {
        "schema_version": NODE_STATE_SCHEMA_VERSION,
        "zone_id": zone_id,
        "node_id": node_id,
        "moisture_raw": payload["mr"],
        "uptime_seconds": payload["up"],
        "health": "ok",
        "last_error": "none",
        "publish_reason": "request_reading",
        "command_message_id": correlation_id,
    }
    if "mp" in payload:
        canonical_payload["moisture_percent"] = payload["mp"]
    if "sq" in payload:
        sequence = payload["sq"]
        if not isinstance(sequence, int) or isinstance(sequence, bool):
            raise ValueError("sq must be an integer")
        if sequence < 1:
            raise ValueError("sq must be greater than or equal to 1")
        canonical_payload["lora_sequence"] = sequence

    reading = validate_sensor_reading(canonical_payload)
    return reading.model_dump(mode="json", by_alias=True, exclude_none=True)


def build_compact_lora_state_publish_request(frame: bytes) -> NodeStatePublishRequest:
    try:
        payload = parse_json_frame(frame)
        return _build_compact_lora_state_publish_request_from_payload(payload, frame)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise InvalidCompactLoRaStateFrameError(
            reason=type(exc).__name__,
            message=str(exc),
        ) from exc


def _build_compact_lora_state_publish_request_from_payload(
    payload: dict[str, Any],
    frame: bytes,
) -> NodeStatePublishRequest:
    canonical_payload = validate_compact_lora_state(payload)
    payload_bytes = json.dumps(canonical_payload, separators=(",", ":")).encode("utf-8")
    reading = validate_sensor_reading(canonical_payload)
    return NodeStatePublishRequest(
        topic=canonical_node_state_topic(reading),
        payload=payload_bytes,
        dedup_key=frame,
    )


def build_node_state_publish_request(frame: bytes) -> NodeStatePublishRequest:
    try:
        payload = parse_json_frame(frame)
        reading = validate_sensor_reading(payload)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise InvalidNodeStateFrameError(
            reason=type(exc).__name__,
            message=str(exc),
        ) from exc

    return NodeStatePublishRequest(
        topic=canonical_node_state_topic(reading),
        payload=frame,
    )


def build_lora_command_ack_publish_request(frame: bytes) -> NodeStatePublishRequest:
    try:
        payload = parse_json_frame(frame)
        ack = validate_lora_command_ack(payload)
        if ack.target != LORA_COMMAND_ACK_TARGET:
            raise ValueError(f"target must be {LORA_COMMAND_ACK_TARGET}")
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise InvalidLoRaCommandAckFrameError(
            reason=type(exc).__name__,
            message=str(exc),
        ) from exc

    return NodeStatePublishRequest(
        topic=canonical_lora_command_ack_topic(ack),
        payload=frame,
    )


def build_lora_frame_publish_request(frame: bytes) -> NodeStatePublishRequest:
    try:
        payload = parse_json_frame(frame)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise InvalidLoRaFrameError(
            reason=type(exc).__name__,
            message=str(exc),
        ) from exc

    schema_version = payload.get("schema_version")
    if payload.get("t") == "state":
        try:
            return _build_compact_lora_state_publish_request_from_payload(payload, frame)
        except ValueError as exc:
            raise InvalidCompactLoRaStateFrameError(
                reason=type(exc).__name__,
                message=str(exc),
            ) from exc

    if schema_version == NODE_STATE_SCHEMA_VERSION:
        try:
            reading = validate_sensor_reading(payload)
        except ValueError as exc:
            raise InvalidNodeStateFrameError(
                reason=type(exc).__name__,
                message=str(exc),
            ) from exc

        return NodeStatePublishRequest(
            topic=canonical_node_state_topic(reading),
            payload=frame,
        )

    if schema_version == LORA_COMMAND_ACK_SCHEMA_VERSION:
        try:
            ack = validate_lora_command_ack(payload)
            if ack.target != LORA_COMMAND_ACK_TARGET:
                raise ValueError(f"target must be {LORA_COMMAND_ACK_TARGET}")
        except ValueError as exc:
            raise InvalidLoRaCommandAckFrameError(
                reason=type(exc).__name__,
                message=str(exc),
            ) from exc

        return NodeStatePublishRequest(
            topic=canonical_lora_command_ack_topic(ack),
            payload=frame,
        )

    raise InvalidLoRaFrameError(
        reason="unsupported_schema_version",
        message=f"unsupported schema_version: {schema_version!r}",
    )
