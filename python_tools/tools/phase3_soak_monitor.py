#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso8601(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def fetch_json(url: str, timeout: float) -> dict[str, Any]:
    with urlopen(url, timeout=timeout) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload)


@dataclass
class MonitorState:
    last_seen_at: datetime | None = None
    config_status: str | None = None
    outage_started_at: datetime | None = None


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True))
        handle.write("\n")


def log_event(path: Path, event_type: str, **fields: Any) -> None:
    append_jsonl(
        path,
        {
            "timestamp": utc_now_iso(),
            "event_type": event_type,
            **fields,
        },
    )


def print_event(message: str) -> None:
    print(f"[{utc_now_iso()}] {message}", flush=True)


def monitor(args: argparse.Namespace) -> int:
    output_path = Path(args.output).expanduser().resolve()
    base_url = args.pi_url.rstrip("/")
    node_status_url = f"{base_url}/setup_api/node_status?node_id={quote(args.node_id, safe='')}"
    bootstrap_url = f"{base_url}/setup_api/bootstrap"
    expected_interval_sec = args.expected_interval_sec
    failure_threshold_sec = max(expected_interval_sec + args.grace_sec, args.poll_interval_sec * 2)

    state = MonitorState()
    start_time = time.monotonic()

    log_event(
        output_path,
        "monitor_started",
        pi_url=base_url,
        node_id=args.node_id,
        expected_interval_sec=expected_interval_sec,
        poll_interval_sec=args.poll_interval_sec,
        grace_sec=args.grace_sec,
        duration_sec=args.duration_sec,
    )
    print_event(
        f"Phase 3 soak monitor started for node={args.node_id} expected_interval={expected_interval_sec}s output={output_path}"
    )

    while True:
        elapsed = time.monotonic() - start_time
        if args.duration_sec and elapsed >= args.duration_sec:
            log_event(output_path, "monitor_finished", reason="duration_reached", elapsed_sec=round(elapsed, 1))
            print_event("Soak monitor finished: duration reached.")
            return 0

        try:
            bootstrap = fetch_json(bootstrap_url, timeout=args.http_timeout_sec)
            node_status = fetch_json(node_status_url, timeout=args.http_timeout_sec)
            node = node_status.get("node") or {}
            last_seen_raw = node.get("last_seen_at")
            last_seen_at = parse_iso8601(last_seen_raw)
            config_status = node.get("config_status")

            if state.outage_started_at is not None:
                outage_duration_sec = round((datetime.now(timezone.utc) - state.outage_started_at).total_seconds(), 1)
                log_event(output_path, "pi_recovered", outage_duration_sec=outage_duration_sec)
                print_event(f"Pi connectivity recovered after {outage_duration_sec}s outage.")
                state.outage_started_at = None

            if state.config_status != config_status:
                log_event(
                    output_path,
                    "config_status_changed",
                    old_status=state.config_status,
                    new_status=config_status,
                )
                print_event(f"Config status changed: {state.config_status!r} -> {config_status!r}")
                state.config_status = config_status

            if last_seen_at and state.last_seen_at and last_seen_at > state.last_seen_at:
                interval_sec = round((last_seen_at - state.last_seen_at).total_seconds(), 1)
                event_type = "publish_interval_observed"
                status = "ok"
                if interval_sec > failure_threshold_sec:
                    event_type = "publish_interval_missed"
                    status = "late"
                log_event(
                    output_path,
                    event_type,
                    last_seen_at=last_seen_raw,
                    previous_last_seen_at=state.last_seen_at.isoformat().replace("+00:00", "Z"),
                    interval_sec=interval_sec,
                    expected_interval_sec=expected_interval_sec,
                    grace_sec=args.grace_sec,
                    status=status,
                    config_status=config_status,
                    zone_publish_interval_ms=((bootstrap.get("first_zone") or {}).get("publish_interval_ms")),
                )
                print_event(f"Publish observed: interval={interval_sec}s status={status}")
            elif last_seen_at and state.last_seen_at is None:
                log_event(
                    output_path,
                    "initial_last_seen",
                    last_seen_at=last_seen_raw,
                    config_status=config_status,
                    zone_publish_interval_ms=((bootstrap.get("first_zone") or {}).get("publish_interval_ms")),
                )
                print_event(f"Initial node state observed: last_seen_at={last_seen_raw}")

            if last_seen_at:
                state.last_seen_at = last_seen_at
            else:
                log_event(output_path, "node_missing_last_seen", config_status=config_status)
                print_event("Node status returned without a last_seen_at value.")

        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as error:
            if state.outage_started_at is None:
                state.outage_started_at = datetime.now(timezone.utc)
                log_event(output_path, "pi_unreachable", error=str(error))
                print_event(f"Pi unreachable: {error}")
            else:
                outage_duration_sec = round((datetime.now(timezone.utc) - state.outage_started_at).total_seconds(), 1)
                log_event(output_path, "pi_still_unreachable", error=str(error), outage_duration_sec=outage_duration_sec)
        except KeyboardInterrupt:
            log_event(output_path, "monitor_finished", reason="keyboard_interrupt")
            print_event("Soak monitor stopped by user.")
            return 130

        time.sleep(args.poll_interval_sec)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Monitor Phase 3 sensor wake/publish intervals on the live Pi.")
    parser.add_argument("--pi-url", default="http://pipi.local:3000", help="Base URL for the Pi web service.")
    parser.add_argument("--node-id", default="sensor-zone1", help="Node ID to monitor.")
    parser.add_argument(
        "--expected-interval-sec",
        type=int,
        default=10800,
        help="Expected publish interval in seconds for the node under test.",
    )
    parser.add_argument(
        "--poll-interval-sec",
        type=int,
        default=20,
        help="How often to poll the Pi for node status.",
    )
    parser.add_argument(
        "--grace-sec",
        type=int,
        default=180,
        help="Extra allowed delay before treating an interval as late.",
    )
    parser.add_argument(
        "--duration-sec",
        type=int,
        default=0,
        help="Optional total runtime. Use 0 to run until interrupted.",
    )
    parser.add_argument(
        "--http-timeout-sec",
        type=float,
        default=5.0,
        help="Per-request HTTP timeout.",
    )
    parser.add_argument(
        "--output",
        default="python_tools/logs/phase3_soak_monitor.jsonl",
        help="JSONL output path.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.expected_interval_sec <= 0:
        parser.error("--expected-interval-sec must be positive")
    if args.poll_interval_sec <= 0:
        parser.error("--poll-interval-sec must be positive")
    if args.grace_sec < 0:
        parser.error("--grace-sec cannot be negative")
    if args.http_timeout_sec <= 0:
        parser.error("--http-timeout-sec must be positive")
    return monitor(args)


if __name__ == "__main__":
    sys.exit(main())
