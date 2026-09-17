from __future__ import annotations

import argparse
import json

from tools import pico_config


class FakeSerial:
    def __init__(self, lines: list[str]):
        self.lines = [line.encode() for line in lines]
        self.writes: list[bytes] = []
        self.port = "/dev/cu.usbmodem-test"

    def write(self, value: bytes) -> None:
        self.writes.append(value)

    def flush(self) -> None:
        return

    def readline(self) -> bytes:
        return self.lines.pop(0) if self.lines else b""


def test_read_ready_parses_only_reported_non_secret_configuration():
    payload = {
        "role": "sensor",
        "node_id": "sensor-zone1",
        "zone_id": "zone1",
        "requires_provisioning": False,
        "wifi_ssid": "GardenNet",
        "mqtt_host": "pipi.local",
        "mqtt_port": 1883,
    }
    port = FakeSerial([f"VG_READY {json.dumps(payload)}\n"])

    ready = pico_config.read_ready(port, timeout=0.1)

    assert ready.wifi_ssid == "GardenNet"
    assert ready.mqtt_host == "pipi.local"
    assert port.writes == [b"VG_IDENTIFY\n"]


def test_update_payload_reads_passwords_from_environment(monkeypatch):
    monkeypatch.setenv("VG_WIFI_PASSWORD", "wifi-secret")
    monkeypatch.setenv("VG_MQTT_PASSWORD", "mqtt-secret")
    ready = pico_config.ReadyConfig(
        port="test",
        role="sensor",
        node_id="saved-node",
        zone_id="saved-zone",
        requires_provisioning=False,
        wifi_ssid="OldNet",
        mqtt_host="old.local",
        mqtt_port=1883,
    )
    args = argparse.Namespace(
        wifi_ssid="GardenNet",
        mqtt_host="pipi.local",
        mqtt_port=1883,
        mqtt_username="victory_garden",
        publish_interval_ms=None,
        utc_offset_hours=None,
        yes=False,
    )

    topology = pico_config.BackendTopology("zone1", "sensor-zone1", ("sensor-zone1-ch0", "sensor-zone1-ch1", "sensor-zone1-ch2", "sensor-zone1-ch3"))
    payload = pico_config.update_payload(args, ready, topology)

    assert payload["wifi_password"] == "wifi-secret"
    assert payload["mqtt_password"] == "mqtt-secret"
    assert payload["node_id"] == "sensor-zone1"
    assert payload["zone_id"] == "zone1"
    assert [channel["node_id"] for channel in payload["channels"]] == list(topology.channel_node_ids)


def test_provision_ack_requires_exact_backend_issued_topology():
    topology = pico_config.BackendTopology("zone1", "sensor-zone1", ("sensor-zone1-ch0", "sensor-zone1-ch1", "sensor-zone1-ch2", "sensor-zone1-ch3"))
    pico_config.verify_provision_ack('VG_PROVISION_OK {"node_id":"sensor-zone1","zone_id":"zone1","channels":["sensor-zone1-ch0","sensor-zone1-ch1","sensor-zone1-ch2","sensor-zone1-ch3"]}', topology)

    try:
        pico_config.verify_provision_ack('VG_PROVISION_OK {"node_id":"sensor-zone1","zone_id":"zone1","channels":["sensor-zone1-ch0","sensor-zone1-ch1","sensor-zone1-ch2","wrong"]}', topology)
    except pico_config.PicoConfigError:
        pass
    else:
        raise AssertionError("mismatched acknowledgement was accepted")


def test_channel_identity_validation_rejects_malformed_or_duplicate_sets():
    for node_ids in (["sensor-zone1-ch0", "sensor-zone1-ch1", "sensor-zone1-ch2"], ["sensor-zone1-ch0"] * 4, ["wrong-ch0", "wrong-ch1", "wrong-ch2", "wrong-ch3"]):
        try:
            pico_config.validate_channel_node_ids("sensor-zone1", node_ids)
        except pico_config.PicoConfigError:
            pass
        else:
            raise AssertionError("invalid channel set was accepted")


def test_mqtt_hosts_equivalent_accepts_hostname_and_its_resolved_ip(monkeypatch):
    addresses = {
        "pipi.local": "192.168.4.38",
        "192.168.4.38": "192.168.4.38",
        "192.168.4.99": "192.168.4.99",
    }
    monkeypatch.setattr(pico_config.socket, "gethostbyname", addresses.__getitem__)

    assert pico_config.mqtt_hosts_equivalent("192.168.4.38", "pipi.local")
    assert not pico_config.mqtt_hosts_equivalent("192.168.4.99", "pipi.local")
