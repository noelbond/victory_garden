from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
import threading
from typing import Any, Callable, Mapping, Protocol

from watering.lora_messages import (
    DEFAULT_LORA_MAX_FRAME_SIZE,
    InvalidLoRaCommandMessageError,
    LoRaCommand,
    build_lora_command_from_mqtt,
    serialize_lora_command_frame,
)
from watering.serial_frames import SerialFrameWriter, SerialFrameWriteStream


class LoRaCommandTransmitter:
    def __init__(
        self,
        stream: SerialFrameWriteStream,
        *,
        max_frame_size: int = DEFAULT_LORA_MAX_FRAME_SIZE,
        initial_sequence: int = 1,
    ) -> None:
        if initial_sequence < 1:
            raise ValueError("initial_sequence must be at least 1")

        self._max_frame_size = max_frame_size
        self._writer = SerialFrameWriter(stream, max_frame_size=max_frame_size)
        self._sequence = initial_sequence
        self._lock = threading.Lock()

    def transmit_command(self, command: LoRaCommand | Mapping[str, Any]) -> bytes:
        with self._lock:
            sequence = self._sequence
            self._sequence += 1

        frame = serialize_lora_command_frame(
            command,
            max_frame_size=self._max_frame_size,
            sequence=sequence,
        )
        self._writer.write_frame(frame)
        return frame

    def transmit_frame(self, frame: bytes) -> bytes:
        if len(frame) > self._max_frame_size:
            raise ValueError("serialized LoRa command frame exceeds max_frame_size")

        self._writer.write_frame(frame)
        return frame


class LoRaCommandSender(Protocol):
    def transmit_command(self, command: LoRaCommand | Mapping[str, Any]) -> bytes:
        """Transmit one validated or validateable LoRa command."""

    def transmit_frame(self, frame: bytes) -> bytes:
        """Retransmit a previously serialized LoRa command frame."""


@dataclass(frozen=True)
class LoRaCommandRouteResult:
    accepted: bool
    reason: str | None = None
    topic: str | None = None
    target_node_id: str | None = None
    message_id: str | None = None
    frame_size: int | None = None


class LoRaCommandRouter:
    def __init__(self, transmitter: LoRaCommandSender, *, recent_command_frames: int = 64) -> None:
        if recent_command_frames < 1:
            raise ValueError("recent_command_frames must be at least 1")

        self._transmitter = transmitter
        self._recent_command_frames = recent_command_frames
        self._cached_frames: OrderedDict[str, tuple[bytes, bytes]] = OrderedDict()

    def route_mqtt_command(self, topic: str, payload: bytes) -> LoRaCommandRouteResult:
        try:
            command = build_lora_command_from_mqtt(topic, payload)
            cached = self._cached_frames.get(command.message_id)
            if cached is None:
                frame = self._transmitter.transmit_command(command)
                self._remember_frame(command.message_id, payload, frame)
            else:
                cached_payload, frame = cached
                if payload != cached_payload:
                    return LoRaCommandRouteResult(
                        accepted=False,
                        reason="duplicate_message_id_payload_mismatch",
                        topic=topic,
                        target_node_id=command.target_node_id,
                        message_id=command.message_id,
                    )
                self._cached_frames.move_to_end(command.message_id)
                frame = self._transmitter.transmit_frame(frame)
        except InvalidLoRaCommandMessageError as exc:
            return LoRaCommandRouteResult(
                accepted=False,
                reason=exc.reason,
                topic=topic,
            )
        except ValueError as exc:
            return LoRaCommandRouteResult(
                accepted=False,
                reason=type(exc).__name__,
                topic=topic,
            )
        except OSError as exc:
            return LoRaCommandRouteResult(
                accepted=False,
                reason=type(exc).__name__,
                topic=topic,
            )

        return LoRaCommandRouteResult(
            accepted=True,
            topic=topic,
            target_node_id=command.target_node_id,
            message_id=command.message_id,
            frame_size=len(frame),
        )

    def _remember_frame(self, message_id: str, payload: bytes, frame: bytes) -> None:
        self._cached_frames[message_id] = (payload, frame)
        self._cached_frames.move_to_end(message_id)
        while len(self._cached_frames) > self._recent_command_frames:
            self._cached_frames.popitem(last=False)


class LoRaCommandRouteTarget:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._router: LoRaCommandRouter | None = None

    def set_router(self, router: LoRaCommandRouter) -> None:
        with self._lock:
            self._router = router

    def clear_router(self, router: LoRaCommandRouter | None = None) -> None:
        with self._lock:
            if router is None or self._router is router:
                self._router = None

    def route_mqtt_command(self, topic: str, payload: bytes) -> LoRaCommandRouteResult:
        with self._lock:
            router = self._router
            if router is None:
                return LoRaCommandRouteResult(
                    accepted=False,
                    reason="serial_disconnected",
                    topic=topic,
                )

            return router.route_mqtt_command(topic, payload)


class LoRaCommandRetryTimer(Protocol):
    def start(self) -> None:
        """Start the pending retry timer."""

    def cancel(self) -> None:
        """Cancel the pending retry timer."""


@dataclass
class _PendingLoRaCommand:
    topic: str
    payload: bytes
    attempts: int
    timer: LoRaCommandRetryTimer | None = None


def _build_daemon_retry_timer(delay_seconds: float, callback: Callable[[], None]) -> LoRaCommandRetryTimer:
    timer = threading.Timer(delay_seconds, callback)
    timer.daemon = True
    return timer


class LoRaCommandRetryController:
    def __init__(
        self,
        route_command: Callable[[str, bytes], LoRaCommandRouteResult],
        *,
        max_attempts: int = 3,
        retry_delay_seconds: float = 6.0,
        timer_factory: Callable[[float, Callable[[], None]], LoRaCommandRetryTimer] = (
            _build_daemon_retry_timer
        ),
        on_retry_result: Callable[[LoRaCommandRouteResult], None] | None = None,
    ) -> None:
        if max_attempts < 1:
            raise ValueError("max_attempts must be at least 1")
        if retry_delay_seconds < 0:
            raise ValueError("retry_delay_seconds must be at least 0")

        self._route_command = route_command
        self._max_attempts = max_attempts
        self._retry_delay_seconds = retry_delay_seconds
        self._timer_factory = timer_factory
        self._on_retry_result = on_retry_result
        self._lock = threading.Lock()
        self._pending: dict[str, _PendingLoRaCommand] = {}

    def route_mqtt_command(self, topic: str, payload: bytes) -> LoRaCommandRouteResult:
        result = self._route_command(topic, payload)
        if result.accepted and result.message_id is not None:
            self._track_command(result.message_id, topic, payload)
        return result

    def mark_command_completed(self, message_id: str) -> None:
        with self._lock:
            pending = self._pending.pop(message_id, None)
        if pending is not None and pending.timer is not None:
            pending.timer.cancel()

    def close(self) -> None:
        with self._lock:
            pending_commands = list(self._pending.values())
            self._pending.clear()
        for pending in pending_commands:
            if pending.timer is not None:
                pending.timer.cancel()

    def _track_command(self, message_id: str, topic: str, payload: bytes) -> None:
        if self._max_attempts <= 1:
            return

        pending = _PendingLoRaCommand(topic=topic, payload=payload, attempts=1)
        timer = self._build_retry_timer(message_id)
        pending.timer = timer

        with self._lock:
            previous = self._pending.get(message_id)
            self._pending[message_id] = pending
        if previous is not None and previous.timer is not None:
            previous.timer.cancel()
        timer.start()

    def _build_retry_timer(self, message_id: str) -> LoRaCommandRetryTimer:
        return self._timer_factory(
            self._retry_delay_seconds,
            lambda: self._retry_command(message_id),
        )

    def _retry_command(self, message_id: str) -> None:
        exhausted_pending: _PendingLoRaCommand | None = None
        with self._lock:
            pending = self._pending.get(message_id)
            if pending is None:
                return
            if pending.attempts >= self._max_attempts:
                exhausted_pending = self._pending.pop(message_id, None)
            else:
                pending.attempts += 1
                topic = pending.topic
                payload = pending.payload

        if exhausted_pending is not None:
            self._notify_retry_exhausted(message_id, exhausted_pending)
            return

        result = self._route_command(topic, payload)
        if self._on_retry_result is not None:
            self._on_retry_result(result)

        exhausted_pending = None
        timer_to_start: LoRaCommandRetryTimer | None = None
        with self._lock:
            pending = self._pending.get(message_id)
            if pending is None:
                return
            if pending.attempts >= self._max_attempts:
                exhausted_pending = self._pending.pop(message_id, None)
            else:
                timer_to_start = self._build_retry_timer(message_id)
                pending.timer = timer_to_start

        if exhausted_pending is not None:
            self._notify_retry_exhausted(message_id, exhausted_pending)
            return

        timer_to_start.start()

    def _notify_retry_exhausted(self, message_id: str, pending: _PendingLoRaCommand) -> None:
        if self._on_retry_result is None:
            return

        self._on_retry_result(
            LoRaCommandRouteResult(
                accepted=False,
                reason="retry_exhausted",
                topic=pending.topic,
                message_id=message_id,
            )
        )
