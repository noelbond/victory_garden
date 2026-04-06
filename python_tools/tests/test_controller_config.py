import json
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace

from watering.controller import (
    LIVE_CROPS,
    LIVE_ZONES,
    LATEST_STATE,
    SYSTEM_CONFIG_TOPIC,
    allowed_now,
    on_message,
    process_zone_tick,
    set_subscriber_context,
    sync_zone_state_subscriptions,
)
from watering.schemas import SensorReading
from watering.state import ZoneState


class FakeClient:
    def __init__(self):
        self.messages: list[tuple[str, str, bool]] = []
        self.subscriptions: list[str] = []
        self.unsubscriptions: list[str] = []

    def publish(self, topic: str, payload: str, retain: bool = False) -> None:
        self.messages.append((topic, payload, retain))

    def subscribe(self, topic: str) -> None:
        self.subscriptions.append(topic)

    def unsubscribe(self, topic: str) -> None:
        self.unsubscriptions.append(topic)


def sample_system_config() -> dict:
    return {
        "crops": [
            {
                "crop_id": "tomato",
                "crop_name": "Tomato",
                "dry_threshold": 30.0,
                "max_pulse_runtime_sec": 45,
                "daily_max_runtime_sec": 300,
            }
        ],
        "zones": [
            {
                "zone_id": "zone1",
                "crop_id": "tomato",
                "node_ids": ["sensor-zone1"],
                "active": True,
                "allowed_hours": {"start_hour": 6, "end_hour": 20},
            }
        ],
    }


def sample_reading() -> SensorReading:
    return SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2500,
        moisture_percent=22.0,
    )


def setup_function():
    LIVE_CROPS.clear()
    LIVE_ZONES.clear()
    LATEST_STATE.clear()
    set_subscriber_context(FakeClient(), {}, None)
    sync_zone_state_subscriptions(reset=True)


def test_system_config_message_populates_live_policy():
    message = SimpleNamespace(
        topic=SYSTEM_CONFIG_TOPIC,
        payload=json.dumps(sample_system_config()).encode("utf-8"),
    )

    on_message(None, None, message)

    assert "tomato" in LIVE_CROPS
    assert "zone1" in LIVE_ZONES
    assert LIVE_ZONES["zone1"].allowed_hours.start_hour == 6
    assert LIVE_ZONES["zone1"].allowed_hours.end_hour == 20


def test_process_zone_tick_skips_watering_outside_allowed_hours():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    reading = sample_reading()
    LATEST_STATE[reading.zone_id] = reading
    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 2, 0, tzinfo=timezone.utc),
        SimpleNamespace(
            min_seconds_between_watering=10800,
            settle_seconds_before_reread=300,
        ),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert zone_runtime["last_processed_signature"]["zone_id"] == "zone1"
    assert states["zone1"].runtime_seconds_today == 0
    assert any(topic.endswith("/controller/skip") for topic, _, _ in client.messages)
    assert not any("request_reading" in payload for _, payload, _ in client.messages)


def test_process_zone_tick_waters_within_allowed_hours():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    reading = sample_reading()
    LATEST_STATE[reading.zone_id] = reading
    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        SimpleNamespace(
            min_seconds_between_watering=10800,
            settle_seconds_before_reread=300,
        ),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    assert zone_runtime["last_watering_signature"]["zone_id"] == "zone1"
    assert any(topic.endswith("/controller/event") for topic, _, _ in client.messages)


def test_allowed_now_uses_local_time_window():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )
    zone = LIVE_ZONES["zone1"]
    assert allowed_now(
        zone,
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        local_tz=timezone(timedelta(hours=-4)),
    )
    assert not allowed_now(
        zone,
        datetime(2026, 3, 31, 6, 0, tzinfo=timezone.utc),
        local_tz=timezone(timedelta(hours=-4)),
    )


def test_system_config_update_subscribes_new_zone_topics():
    client = FakeClient()
    set_subscriber_context(client, {}, None)
    sync_zone_state_subscriptions(reset=True)

    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    assert "greenhouse/zones/zone1/state" in client.subscriptions
