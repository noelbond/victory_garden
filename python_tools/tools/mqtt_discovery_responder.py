from __future__ import annotations

import argparse
import json
import socket
from datetime import UTC, datetime


DISCOVERY_SCHEMA = "mqtt-discovery/v1"
DISCOVERY_COMMAND = "discover"


def parse_discovery_request(payload: bytes) -> bool:
    try:
        message = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return (
        message.get("schema_version") == DISCOVERY_SCHEMA
        and message.get("command") == DISCOVERY_COMMAND
    )


def build_discovery_response(mqtt_host: str, mqtt_port: int) -> bytes:
    payload = {
        "schema_version": DISCOVERY_SCHEMA,
        "mqtt_host": mqtt_host,
        "mqtt_port": mqtt_port,
    }
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def resolve_local_ip_for_peer(peer_host: str, peer_port: int) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect((peer_host, peer_port))
        return probe.getsockname()[0]


def run_server(bind_host: str, discovery_port: int, mqtt_port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((bind_host, discovery_port))
        print(
            json.dumps(
                {
                    "component": "mqtt_discovery",
                    "event": "listening",
                    "bind_host": bind_host,
                    "discovery_port": discovery_port,
                    "mqtt_port": mqtt_port,
                    "timestamp": datetime.now(UTC).isoformat(),
                },
                separators=(",", ":"),
            ),
            flush=True,
        )

        while True:
            payload, peer = server.recvfrom(2048)
            if not parse_discovery_request(payload):
                continue

            mqtt_host = resolve_local_ip_for_peer(peer[0], peer[1])
            response = build_discovery_response(mqtt_host, mqtt_port)
            server.sendto(response, peer)
            print(
                json.dumps(
                    {
                        "component": "mqtt_discovery",
                        "event": "responded",
                        "peer_host": peer[0],
                        "peer_port": peer[1],
                        "mqtt_host": mqtt_host,
                        "mqtt_port": mqtt_port,
                        "timestamp": datetime.now(UTC).isoformat(),
                    },
                    separators=(",", ":"),
                ),
                flush=True,
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Respond to Pico broker discovery requests.")
    parser.add_argument("--bind-host", default="0.0.0.0")
    parser.add_argument("--discovery-port", type=int, default=44737)
    parser.add_argument("--mqtt-port", type=int, default=1883)
    args = parser.parse_args()
    run_server(args.bind_host, args.discovery_port, args.mqtt_port)


if __name__ == "__main__":
    main()
