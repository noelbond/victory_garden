import pytest

from watering.serial_frames import SerialFrameWriter


class FakeWriteStream:
    def __init__(self):
        self.writes = []
        self.flushes = 0

    def write(self, data):
        self.writes.append(data)
        return len(data)

    def flush(self):
        self.flushes += 1


class TestSerialFrameWriter:
    def test_writes_newline_delimited_frame_and_flushes(self):
        stream = FakeWriteStream()
        writer = SerialFrameWriter(stream)

        writer.write_frame(b'{"schema_version":"lora-command/v1"}')

        assert stream.writes == [b'{"schema_version":"lora-command/v1"}\n']
        assert stream.flushes == 1

    def test_accepts_bytearray_and_memoryview(self):
        stream = FakeWriteStream()
        writer = SerialFrameWriter(stream)

        writer.write_frame(bytearray(b"one"))
        writer.write_frame(memoryview(b"two"))

        assert stream.writes == [b"one\n", b"two\n"]
        assert stream.flushes == 2

    def test_rejects_embedded_newline_or_carriage_return(self):
        writer = SerialFrameWriter(FakeWriteStream())

        with pytest.raises(ValueError, match="must not contain CR or LF"):
            writer.write_frame(b"bad\nframe")

        with pytest.raises(ValueError, match="must not contain CR or LF"):
            writer.write_frame(b"bad\rframe")

    def test_rejects_oversized_frame(self):
        writer = SerialFrameWriter(FakeWriteStream(), max_frame_size=3)

        with pytest.raises(ValueError, match="exceeds max_frame_size"):
            writer.write_frame(b"abcd")

    def test_accepts_frame_at_max_size(self):
        stream = FakeWriteStream()
        writer = SerialFrameWriter(stream, max_frame_size=3)

        writer.write_frame(b"abc")

        assert stream.writes == [b"abc\n"]
        assert stream.flushes == 1

    def test_rejects_invalid_max_frame_size(self):
        with pytest.raises(ValueError, match="max_frame_size must be at least 1"):
            SerialFrameWriter(FakeWriteStream(), max_frame_size=0)
