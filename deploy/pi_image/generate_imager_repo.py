#!/usr/bin/env python3
"""Generate Raspberry Pi Imager repository JSON for a Victory Garden image."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import lzma
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_xz_contents(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with lzma.open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(chunk)
            digest.update(chunk)
    return digest.hexdigest(), size


def file_url(path: Path) -> str:
    return path.resolve().as_uri()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a Raspberry Pi Imager repository JSON file for a "
            "Victory Garden image artifact."
        )
    )
    parser.add_argument("--image", required=True, help="Path to the .img.xz artifact")
    parser.add_argument("--output", required=True, help="Path to write the JSON file")
    parser.add_argument(
        "--image-url",
        help=(
            "Public or local URL for the image. Defaults to a file:// URL for "
            "the provided image path."
        ),
    )
    parser.add_argument(
        "--image-name",
        default="Victory Garden Pi 64-bit",
        help="Display name for the image entry",
    )
    parser.add_argument(
        "--description",
        default=(
            "Victory Garden image for Raspberry Pi 4, "
            "Raspberry Pi 5, and Compute Module 4/5 targets."
        ),
        help="Description shown in Raspberry Pi Imager",
    )
    parser.add_argument(
        "--release-date",
        default=None,
        help="Release date in YYYY-MM-DD format. Defaults to the image mtime.",
    )
    parser.add_argument(
        "--homepage-url",
        default="https://www.raspberrypi.com/software/",
        help="Homepage URL used in the top-level Imager metadata",
    )
    parser.add_argument(
        "--latest-imager-version",
        default="2.0.0",
        help="Latest Imager version string placed in repo metadata",
    )
    parser.add_argument(
        "--icon-url",
        default="https://www.raspberrypi.com/app/uploads/2021/06/cropped-RPi-Logo-Reg-SCREEN-1-32x32.png",
        help="Icon URL shown next to the image entry",
    )
    parser.add_argument(
        "--hostname",
        default="victory-garden",
        help="Default hostname noted in the description text",
    )
    parser.add_argument(
        "--init-format",
        default="systemd",
        choices=("none", "systemd", "cloudinit", "cloudinit-rpi"),
        help="Imager customisation mechanism for this image",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    image_path = Path(args.image)
    output_path = Path(args.output)

    if not image_path.is_file():
        fail(f"Image artifact not found: {image_path}")

    if image_path.suffix != ".xz" or not image_path.name.endswith(".img.xz"):
        fail("Expected an .img.xz artifact")

    image_url = args.image_url or file_url(image_path)
    image_download_size = image_path.stat().st_size
    image_download_sha256 = sha256_path(image_path)
    extract_sha256, extract_size = sha256_xz_contents(image_path)

    release_date = args.release_date
    if not release_date:
        release_date = dt.date.fromtimestamp(image_path.stat().st_mtime).isoformat()

    hostname_note = (
        f"Default hostname is {args.hostname}.local until changed in the Victory Garden installer."
    )
    installer_note = "After first boot, finish setup in the Victory Garden desktop installer."

    repo = {
        "imager": {
            "latest_version": args.latest_imager_version,
            "url": args.homepage_url,
            "devices": [
                {
                    "name": "Victory Garden-compatible Raspberry Pi",
                    "description": (
                        "Raspberry Pi 4, Raspberry Pi 5, and compatible Compute Module targets"
                    ),
                    "tags": ["victory-garden"],
                    "default": True,
                    "matching_type": "inclusive",
                }
            ],
        },
        "os_list": [
            {
                "name": args.image_name,
                "description": f"{args.description} {hostname_note} {installer_note}",
                "icon": args.icon_url,
                "url": image_url,
                "extract_size": extract_size,
                "extract_sha256": extract_sha256,
                "image_download_size": image_download_size,
                "image_download_sha256": image_download_sha256,
                "release_date": release_date,
                "init_format": args.init_format,
                "devices": ["victory-garden"],
            }
        ],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(repo, indent=2) + "\n", encoding="utf-8")

    print(f"Created Raspberry Pi Imager repository JSON: {output_path}")
    print(f"Image URL: {image_url}")


if __name__ == "__main__":
    main()
