"""Newline-delimited serial frame encoding and decoding."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class SerialFrameDecodeError:
    reason: str
    message: str


@dataclass(frozen=True)
class SerialFrameDecodeResult:
    frames: list[bytes]
    errors: list[SerialFrameDecodeError]


class SerialFrameWriteStream(Protocol):
    def write(self, data: bytes) -> int | None:
        """Write bytes to a stream."""

    def flush(self) -> None:
        """Flush buffered bytes to the stream."""


class SerialFrameDecoder:
    """Incrementally decode newline-delimited frames from serial byte chunks."""

    def __init__(self, *, max_frame_size: int = 1024) -> None:
        if max_frame_size < 1:
            raise ValueError("max_frame_size must be at least 1")

        self.max_frame_size = max_frame_size
        self._buffer = bytearray()
        self._discarding_frame = False

    def feed(self, chunk: bytes | bytearray | memoryview) -> SerialFrameDecodeResult:
        self._buffer.extend(chunk)
        frames: list[bytes] = []
        errors: list[SerialFrameDecodeError] = []

        while True:
            if self._discarding_frame:
                newline_index = self._buffer.find(b"\n")
                if newline_index == -1:
                    self._buffer.clear()
                    return SerialFrameDecodeResult(frames=frames, errors=errors)

                del self._buffer[: newline_index + 1]
                self._discarding_frame = False
                continue

            newline_index = self._buffer.find(b"\n")
            if newline_index == -1:
                if self._content_size(self._buffer) > self.max_frame_size:
                    self._buffer.clear()
                    self._discarding_frame = True
                    errors.append(self._oversized_frame_error())
                return SerialFrameDecodeResult(frames=frames, errors=errors)

            frame = bytes(self._buffer[:newline_index]).rstrip(b"\r")
            if len(frame) > self.max_frame_size:
                del self._buffer[: newline_index + 1]
                errors.append(self._oversized_frame_error())
                continue

            del self._buffer[: newline_index + 1]
            frames.append(frame)

    def reset(self) -> None:
        self._buffer.clear()
        self._discarding_frame = False

    def _content_size(self, buffer: bytearray) -> int:
        if buffer.endswith(b"\r"):
            return len(buffer) - 1
        return len(buffer)

    def _oversized_frame_error(self) -> SerialFrameDecodeError:
        return SerialFrameDecodeError(
            reason="frame_too_large",
            message="serial frame exceeds max_frame_size",
        )


class SerialFrameWriter:
    """Write newline-delimited serial frames."""

    def __init__(self, stream: SerialFrameWriteStream, *, max_frame_size: int = 1024) -> None:
        if max_frame_size < 1:
            raise ValueError("max_frame_size must be at least 1")

        self._stream = stream
        self.max_frame_size = max_frame_size

    def write_frame(self, frame: bytes | bytearray | memoryview) -> None:
        payload = bytes(frame)
        if b"\n" in payload or b"\r" in payload:
            raise ValueError("serial frame payload must not contain CR or LF")
        if len(payload) > self.max_frame_size:
            raise ValueError("serial frame exceeds max_frame_size")

        self._stream.write(payload + b"\n")
        self._stream.flush()
