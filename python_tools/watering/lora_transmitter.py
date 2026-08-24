from __future__ import annotations

from dataclasses import dataclass
import threading
from typing import Any, Mapping, Protocol

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
    ) -> None:
        self._max_frame_size = max_frame_size
        self._writer = SerialFrameWriter(stream, max_frame_size=max_frame_size)

    def transmit_command(self, command: LoRaCommand | Mapping[str, Any]) -> bytes:
        frame = serialize_lora_command_frame(command, max_frame_size=self._max_frame_size)
        self._writer.write_frame(frame)
        return frame


class LoRaCommandSender(Protocol):
    def transmit_command(self, command: LoRaCommand | Mapping[str, Any]) -> bytes:
        """Transmit one validated or validateable LoRa command."""


@dataclass(frozen=True)
class LoRaCommandRouteResult:
    accepted: bool
    reason: str | None = None
    topic: str | None = None
    target_node_id: str | None = None
    message_id: str | None = None
    frame_size: int | None = None


class LoRaCommandRouter:
    def __init__(self, transmitter: LoRaCommandSender) -> None:
        self._transmitter = transmitter

    def route_mqtt_command(self, topic: str, payload: bytes) -> LoRaCommandRouteResult:
        try:
            command = build_lora_command_from_mqtt(topic, payload)
            frame = self._transmitter.transmit_command(command)
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
