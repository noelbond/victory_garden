from __future__ import annotations

import argparse
import os


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run watering control loop from live MQTT state."
    )
    parser.add_argument(
        "--zone-id",
        help="Zone to run (default: all configured zones).",
    )
    parser.add_argument("--mqtt-host", default="127.0.0.1")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--mqtt-username", default=os.environ.get("MQTT_USERNAME"))
    parser.add_argument("--mqtt-password", default=os.environ.get("MQTT_PASSWORD"))
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=1.0,
        help="How often to check whether a new MQTT reading arrived.",
    )
    parser.add_argument(
        "--min-seconds-between-watering",
        type=int,
        default=10800,
        help="Cooldown between watering actions per zone in seconds (default: 3 hours).",
    )
    parser.add_argument(
        "--max-reading-age-seconds",
        type=int,
        default=900,
        help="Maximum age of a sensor reading before the controller refuses to act on it (default: 15 minutes).",
    )
    parser.add_argument(
        "--min-zone-sensor-readings",
        type=int,
        default=1,
        help="Minimum fresh sensor readings required before a zone watering decision is allowed (default: 1).",
    )
    parser.add_argument(
        "--startup-timeout-seconds",
        type=int,
        default=120,
        help="Seconds to wait for the first MQTT reading before giving up (default: 120).",
    )
    return parser
