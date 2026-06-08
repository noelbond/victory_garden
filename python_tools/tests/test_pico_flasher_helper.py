from __future__ import annotations

from pathlib import Path

import pytest

from tools import pico_flasher_helper as helper


def test_infer_board_from_volume_name():
    assert helper.infer_board_from_volume_name("RPI-RP2") == "pico_w"
    assert helper.infer_board_from_volume_name("RP2350") == "pico2_w"
    assert helper.infer_board_from_volume_name("OTHER") is None


def test_list_bootsel_devices_detects_supported_mounts(tmp_path: Path):
    (tmp_path / "RPI-RP2").mkdir()
    (tmp_path / "RP2350").mkdir()
    (tmp_path / "unrelated").mkdir()

    devices = helper.list_bootsel_devices([tmp_path])

    assert [device.board for device in devices] == ["pico2_w", "pico_w"]
    assert [device.volume_name for device in devices] == ["RP2350", "RPI-RP2"]


def test_resolve_single_device_rejects_zero_or_multiple_matches():
    with pytest.raises(helper.PicoFlasherError, match="No mounted pico2_w BOOTSEL device detected"):
        helper.resolve_single_device([], "pico2_w")

    devices = [
        helper.BootselDevice(board="pico2_w", volume_name="RP2350", mount_path="/Volumes/RP2350"),
        helper.BootselDevice(board="pico2_w", volume_name="RP2350", mount_path="/Volumes/RP2350-2"),
    ]
    with pytest.raises(helper.PicoFlasherError, match="Multiple pico2_w BOOTSEL devices detected"):
        helper.resolve_single_device(devices, "pico2_w")


def test_flash_firmware_to_device_writes_uf2(tmp_path: Path):
    device = helper.BootselDevice(board="pico2_w", volume_name="RP2350", mount_path=str(tmp_path))

    flashed_path = helper.flash_firmware_to_device(device, "pico2_w_actuator_node.uf2", b"UF2DATA")

    assert flashed_path.read_bytes() == b"UF2DATA"


def test_flash_firmware_to_device_rejects_non_uf2(tmp_path: Path):
    device = helper.BootselDevice(board="pico_w", volume_name="RPI-RP2", mount_path=str(tmp_path))

    with pytest.raises(helper.PicoFlasherError, match="Refusing to flash non-UF2 file"):
        helper.flash_firmware_to_device(device, "bad.bin", b"x")
