from __future__ import annotations

import argparse

from watering.relay_gpio import RelayGPIOConfig, RelayGPIOController
from watering.structured_logging import log_event


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Relay-backed actuator hook for the Victory Garden actuator daemon.")
    parser.add_argument("action", choices=["start", "stop"])
    parser.add_argument("zone_id")
    parser.add_argument("runtime_seconds", nargs="?", default="")
    parser.add_argument("idempotency_key", nargs="?", default="")
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    controller = RelayGPIOController(RelayGPIOConfig.from_env())
    controller.prepare()

    if args.action == "start":
        controller.set_enabled(True)
    else:
        controller.set_enabled(False)

    log_event(
        "relay_gpio",
        "hook_invoked",
        action=args.action,
        zone_id=args.zone_id,
        runtime_seconds=args.runtime_seconds or None,
        idempotency_key=args.idempotency_key or None,
        gpio_pin=controller.config.gpio_pin,
        active_low=controller.config.active_low,
    )


if __name__ == "__main__":
    main()
