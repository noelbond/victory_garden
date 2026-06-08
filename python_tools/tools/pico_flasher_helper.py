from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HELPER_VERSION = "0.1.0"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 48123

BOARD_BOOT_DRIVES = {
    "pico_w": "RPI-RP2",
    "pico2_w": "RP2350",
}


@dataclass(frozen=True)
class BootselDevice:
    board: str
    volume_name: str
    mount_path: str


class PicoFlasherError(RuntimeError):
    pass


def firmware_download_filename(kind: str, board: str) -> str:
    by_kind = {
        "sensor": {
            "pico_w": "pico_w_sensor_node.uf2",
            "pico2_w": "pico2_w_sensor_node.uf2",
        },
        "actuator": {
            "pico_w": "pico_w_actuator_node.uf2",
            "pico2_w": "pico2_w_actuator_node.uf2",
        },
    }
    try:
        return by_kind[kind][board]
    except KeyError as exc:
        raise PicoFlasherError(f"Unsupported firmware kind/board combination: {kind}/{board}") from exc


def infer_board_from_volume_name(volume_name: str) -> str | None:
    for board, boot_drive in BOARD_BOOT_DRIVES.items():
        if volume_name == boot_drive:
            return board
    return None


def candidate_volume_roots() -> list[Path]:
    roots: list[Path] = []
    if os.name == "posix" and Path("/Volumes").exists():
        roots.append(Path("/Volumes"))

    home = Path.home()
    for base in (
        home / "media",
        Path("/media") / home.name,
        Path("/run/media") / home.name,
    ):
        if base.exists():
            roots.append(base)
    return roots


def list_bootsel_devices(volume_roots: list[Path] | None = None) -> list[BootselDevice]:
    roots = volume_roots or candidate_volume_roots()
    devices: list[BootselDevice] = []

    for root in roots:
        if not root.exists():
            continue

        for entry in root.iterdir():
            if not entry.is_dir():
                continue
            board = infer_board_from_volume_name(entry.name)
            if not board:
                continue
            devices.append(
                BootselDevice(
                    board=board,
                    volume_name=entry.name,
                    mount_path=str(entry),
                )
            )

    devices.sort(key=lambda device: (device.board, device.mount_path))
    return devices


def resolve_single_device(devices: list[BootselDevice], board: str) -> BootselDevice:
    matching = [device for device in devices if device.board == board]
    if not matching:
        raise PicoFlasherError(f"No mounted {board} BOOTSEL device detected.")
    if len(matching) > 1:
        mount_paths = ", ".join(device.mount_path for device in matching)
        raise PicoFlasherError(f"Multiple {board} BOOTSEL devices detected: {mount_paths}")
    return matching[0]


def download_firmware(url: str) -> tuple[bytes, str]:
    request = urllib.request.Request(url, headers={"User-Agent": "VictoryGardenPicoFlasher/0.1"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read()
            content_disposition = response.headers.get("Content-Disposition", "")
    except urllib.error.URLError as exc:
        raise PicoFlasherError(f"Could not download firmware from {url}: {exc}") from exc

    filename = ""
    marker = "filename="
    if marker in content_disposition:
        filename = content_disposition.split(marker, 1)[1].strip().strip('"')
        filename = filename.split(";")[0].strip()
    return payload, filename


def flash_firmware_to_device(device: BootselDevice, filename: str, payload: bytes) -> Path:
    if not filename.endswith(".uf2"):
        raise PicoFlasherError(f"Refusing to flash non-UF2 file: {filename}")

    target_path = Path(device.mount_path) / filename
    try:
        with target_path.open("wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as exc:
        raise PicoFlasherError(f"Could not write firmware to {target_path}: {exc}") from exc

    return target_path


def handle_flash_request(payload: dict[str, Any]) -> dict[str, Any]:
    board = str(payload.get("board") or "")
    kind = str(payload.get("kind") or "")
    firmware_url = str(payload.get("firmware_url") or "")

    if board not in BOARD_BOOT_DRIVES:
        raise PicoFlasherError(f"Unsupported board: {board}")
    if kind not in {"sensor", "actuator"}:
        raise PicoFlasherError(f"Unsupported firmware kind: {kind}")
    if not firmware_url:
        raise PicoFlasherError("Missing firmware_url.")

    devices = list_bootsel_devices()
    device = resolve_single_device(devices, board)
    firmware_bytes, response_filename = download_firmware(firmware_url)
    filename = response_filename or firmware_download_filename(kind, board)
    flashed_path = flash_firmware_to_device(device, filename, firmware_bytes)

    return {
        "ok": True,
        "board": board,
        "kind": kind,
        "device": asdict(device),
        "flashed_filename": flashed_path.name,
        "flashed_path": str(flashed_path),
    }


class PicoFlasherHandler(BaseHTTPRequestHandler):
    server_version = "VictoryGardenPicoFlasher/0.1"

    def log_message(self, format: str, *args: Any) -> None:
        return

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        super().end_headers()

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def do_GET(self) -> None:
        if self.path == "/v1/status":
            self.respond_json(
                {
                    "ok": True,
                    "service": "pico-flasher-helper",
                    "version": HELPER_VERSION,
                    "devices": [asdict(device) for device in list_bootsel_devices()],
                }
            )
            return

        self.respond_json({"ok": False, "error": "Not found"}, status=HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        if self.path != "/v1/flash":
            self.respond_json({"ok": False, "error": "Not found"}, status=HTTPStatus.NOT_FOUND)
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(content_length)
            payload = json.loads(raw_body.decode("utf-8"))
            response = handle_flash_request(payload)
            self.respond_json(response, status=HTTPStatus.CREATED)
        except PicoFlasherError as exc:
            self.respond_json({"ok": False, "error": str(exc)}, status=HTTPStatus.BAD_REQUEST)
        except json.JSONDecodeError:
            self.respond_json({"ok": False, "error": "Invalid JSON body."}, status=HTTPStatus.BAD_REQUEST)

    def respond_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(host: str, port: int) -> None:
    server = ThreadingHTTPServer((host, port), PicoFlasherHandler)
    print(f"Victory Garden Pico Flasher listening on http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Victory Garden Pico flasher helper")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--status", action="store_true", help="Print detected BOOTSEL devices as JSON and exit.")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.status:
        print(
            json.dumps(
                {
                    "ok": True,
                    "service": "pico-flasher-helper",
                    "version": HELPER_VERSION,
                    "devices": [asdict(device) for device in list_bootsel_devices()],
                },
                indent=2,
            )
        )
        return

    serve(args.host, args.port)


if __name__ == "__main__":
    main()
