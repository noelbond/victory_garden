from __future__ import annotations

import json

from tools.mqtt_discovery_responder import (
    build_discovery_response,
    parse_discovery_request,
)


def test_parse_discovery_request_accepts_valid_message():
    payload = b'{"schema_version":"mqtt-discovery/v1","command":"discover"}'
    assert parse_discovery_request(payload) is True


def test_parse_discovery_request_rejects_invalid_message():
    payload = b'{"schema_version":"mqtt-discovery/v1","command":"other"}'
    assert parse_discovery_request(payload) is False


def test_build_discovery_response_encodes_host_and_port():
    payload = build_discovery_response("192.168.4.26", 1883)
    assert json.loads(payload.decode("utf-8")) == {
        "schema_version": "mqtt-discovery/v1",
        "mqtt_host": "192.168.4.26",
        "mqtt_port": 1883,
    }
