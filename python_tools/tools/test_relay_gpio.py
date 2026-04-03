from __future__ import annotations

import argparse
import time

from watering.relay_gpio import RelayGPIOConfig, RelayGPIOController


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Toggle the Pi relay GPIO for isolated hardware bring-up.")
    parser.add_argument("--pin", type=int, default=17, help="BCM GPIO pin connected to relay IN")
    parser.add_argument("--cycles", type=int, default=5, help="Number of on/off cycles to run")
    parser.add_argument("--on-seconds", type=float, default=2.0, help="Seconds to hold relay ON")
    parser.add_argument("--off-seconds", type=float, default=2.0, help="Seconds to hold relay OFF")
    parser.add_argument(
        "--active-low",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Treat LOW as relay ON (default true)",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    controller = RelayGPIOController(
        RelayGPIOConfig(gpio_pin=args.pin, active_low=args.active_low)
    )
    controller.prepare()

    try:
        for _ in range(args.cycles):
            controller.set_enabled(True)
            time.sleep(args.on_seconds)
            controller.set_enabled(False)
            time.sleep(args.off_seconds)
    finally:
        controller.set_enabled(False)


if __name__ == "__main__":
    main()
