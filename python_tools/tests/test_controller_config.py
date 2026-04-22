import json
import tempfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

from watering.controller import (
    LIVE_CROPS,
    LIVE_ZONES,
    LATEST_STATE,
    LATEST_ZONE_READINGS,
    SYSTEM_CONFIG_TOPIC,
    allowed_now,
    load_controller_runtime,
    on_message,
    process_zone_tick,
    reading_ready_for_control,
    save_controller_runtime,
    set_subscriber_context,
    store_latest_reading,
    sync_zone_state_subscriptions,
    zone_moisture_snapshot,
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
                "irrigation_line": 1,
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


def controller_args():
    return SimpleNamespace(
        min_seconds_between_watering=10800,
        max_reading_age_seconds=900,
        min_zone_sensor_readings=1,
        settle_seconds_before_reread=300,
    )


def setup_function():
    LIVE_CROPS.clear()
    LIVE_ZONES.clear()
    LATEST_STATE.clear()
    LATEST_ZONE_READINGS.clear()
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
        controller_args(),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert zone_runtime["last_skip_signature"]["zone_id"] == "zone1"
    assert zone_runtime["last_skip_reason"] == "outside_allowed_hours"
    assert states["zone1"].runtime_seconds_today == 0
    assert any(topic.endswith("/controller/skip") for topic, _, _ in client.messages)
    assert not any("request_reading" in payload for _, payload, _ in client.messages)


def test_process_zone_tick_reuses_dry_reading_when_allowed_window_opens():
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
    states = {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))}

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        states,
        datetime(2026, 3, 31, 2, 0, tzinfo=timezone.utc),
        controller_args(),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        controller_args(),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    assert any(topic.endswith("/controller/event") for topic, _, _ in client.messages)


def test_process_zone_tick_only_publishes_outside_allowed_skip_once_per_signature():
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
    args = controller_args()

    zone_runtime, _states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 2, 0, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    process_zone_tick(
        zone,
        profile,
        zone_runtime,
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 2, 1, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    skip_topics = [topic for topic, _, _ in client.messages if topic.endswith("/controller/skip")]
    assert len(skip_topics) == 1


def test_process_zone_tick_reuses_low_reading_after_cooldown_expires():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()
    initial_states = {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))}

    first_reading = sample_reading()
    LATEST_STATE[first_reading.zone_id] = first_reading
    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        initial_states,
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    reread = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2400,
        moisture_percent=21.0,
        wake_count=2,
    )
    LATEST_STATE[reread.zone_id] = reread

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 10, 5, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 13, 5, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 90
    assert any(topic.endswith("/controller/skip") for topic, _, _ in client.messages)
    assert len([topic for topic, _, _ in client.messages if topic.endswith("/controller/event")]) == 2


def test_process_zone_tick_only_publishes_cooldown_skip_once_per_signature():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()

    first_reading = sample_reading()
    LATEST_STATE[first_reading.zone_id] = first_reading
    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    reread = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2400,
        moisture_percent=21.0,
        wake_count=2,
    )
    LATEST_STATE[reread.zone_id] = reread

    zone_runtime, _states = process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 10, 5, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 10, 6, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    skip_topics = [topic for topic, _, _ in client.messages if topic.endswith("/controller/skip")]
    assert len(skip_topics) == 1


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
        controller_args(),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    assert zone_runtime["last_watering_signature"]["zone_id"] == "zone1"
    assert any(topic.endswith("/controller/event") for topic, _, _ in client.messages)


def test_restart_with_persisted_controller_runtime_does_not_republish_same_retained_reading():
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
    args = controller_args()

    first_client = FakeClient()
    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        first_client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        runtime_path = Path(f.name)

    try:
        save_controller_runtime(runtime_path, {"zone1": zone_runtime})
        loaded_runtime = load_controller_runtime(runtime_path)
    finally:
        runtime_path.unlink()

    restart_client = FakeClient()
    reloaded_zone_runtime, states = process_zone_tick(
        zone,
        profile,
        loaded_runtime["zone1"],
        states,
        datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
        args,
        restart_client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    assert restart_client.messages == []
    assert reloaded_zone_runtime["last_processed_signature"]["zone_id"] == "zone1"


def test_restart_with_persisted_cooldown_skip_does_not_repeat_skip_for_same_reading():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    args = controller_args()

    first_reading = sample_reading()
    LATEST_STATE[first_reading.zone_id] = first_reading
    first_client = FakeClient()
    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        first_client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    reread = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2400,
        moisture_percent=21.0,
        wake_count=2,
    )
    LATEST_STATE[reread.zone_id] = reread

    cooldown_client = FakeClient()
    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 10, 5, tzinfo=timezone.utc),
        args,
        cooldown_client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        runtime_path = Path(f.name)

    try:
        save_controller_runtime(runtime_path, {"zone1": zone_runtime})
        loaded_runtime = load_controller_runtime(runtime_path)
    finally:
        runtime_path.unlink()

    restart_client = FakeClient()
    process_zone_tick(
        zone,
        profile,
        loaded_runtime["zone1"],
        states,
        datetime(2026, 3, 31, 10, 6, tzinfo=timezone.utc),
        args,
        restart_client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert loaded_runtime["zone1"]["last_skip_reason"] == "cooldown"
    assert [topic for topic, _, _ in restart_client.messages if topic.endswith("/controller/skip")] == []


def test_corrupt_controller_runtime_is_quarantined():
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        runtime_path = Path(f.name)

    try:
        runtime_path.write_text("{not valid json")
        loaded_runtime = load_controller_runtime(runtime_path)

        assert loaded_runtime == {}
        assert not runtime_path.exists()

        quarantined = list(runtime_path.parent.glob(f"{runtime_path.stem}.corrupt-*{runtime_path.suffix}"))
        assert len(quarantined) == 1
        assert quarantined[0].exists()
    finally:
        if runtime_path.exists():
            runtime_path.unlink()
        for quarantined_path in runtime_path.parent.glob(f"{runtime_path.stem}.corrupt-*{runtime_path.suffix}"):
            quarantined_path.unlink()


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
    assert "greenhouse/zones/zone1/nodes/+/state" in client.subscriptions


def test_zone_moisture_snapshot_averages_fresh_configured_sensors():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(
                {
                    "crops": sample_system_config()["crops"],
                    "zones": [
                        {
                            "zone_id": "zone1",
                            "crop_id": "tomato",
                            "node_ids": ["sensor-a", "sensor-b", "sensor-c"],
                            "active": True,
                            "allowed_hours": {"start_hour": 6, "end_hour": 20},
                            "irrigation_line": 1,
                        }
                    ],
                }
            ).encode("utf-8"),
        ),
    )

    for node_id, moisture in [("sensor-a", 20.0), ("sensor-b", 30.0), ("sensor-c", 40.0)]:
        store_latest_reading(
            SensorReading(
                node_id=node_id,
                zone_id="zone1",
                moisture_raw=2500,
                moisture_percent=moisture,
                timestamp=datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
            )
        )

    snapshot = zone_moisture_snapshot(
        LIVE_ZONES["zone1"],
        now=datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
        max_age_seconds=900,
    )

    assert snapshot is not None
    assert snapshot.reading.moisture_percent == 30.0
    assert snapshot.valid_sensor_count == 3
    assert snapshot.expected_sensor_count == 3
    assert snapshot.valid_node_ids == ["sensor-a", "sensor-b", "sensor-c"]


def test_process_zone_tick_skips_when_valid_sensor_count_below_quorum():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(
                {
                    "crops": sample_system_config()["crops"],
                    "zones": [
                        {
                            "zone_id": "zone1",
                            "crop_id": "tomato",
                            "node_ids": ["sensor-a", "sensor-b", "sensor-c", "sensor-d", "sensor-e", "sensor-f"],
                            "active": True,
                            "allowed_hours": {"start_hour": 6, "end_hour": 20},
                            "irrigation_line": 1,
                        }
                    ],
                }
            ).encode("utf-8"),
        ),
    )

    for node_id, moisture in [("sensor-a", 20.0), ("sensor-b", 21.0), ("sensor-c", 22.0)]:
        store_latest_reading(
            SensorReading(
                node_id=node_id,
                zone_id="zone1",
                moisture_raw=2500,
                moisture_percent=moisture,
                timestamp=datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
            )
        )

    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()
    args.min_zone_sensor_readings = 4

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert zone_runtime["last_skip_reason"] == "insufficient_sensor_quorum"
    assert states["zone1"].runtime_seconds_today == 0
    assert any(payload and "insufficient_sensor_quorum" in payload for _, payload, _ in client.messages)
    assert not any(topic.endswith("/actuator/command") for topic, _, _ in client.messages)


def test_process_zone_tick_waters_when_quorum_average_is_dry():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(
                {
                    "crops": sample_system_config()["crops"],
                    "zones": [
                        {
                            "zone_id": "zone1",
                            "crop_id": "tomato",
                            "node_ids": ["sensor-a", "sensor-b", "sensor-c", "sensor-d", "sensor-e", "sensor-f"],
                            "active": True,
                            "allowed_hours": {"start_hour": 6, "end_hour": 20},
                            "irrigation_line": 1,
                        }
                    ],
                }
            ).encode("utf-8"),
        ),
    )

    for node_id, moisture in [("sensor-a", 20.0), ("sensor-b", 22.0), ("sensor-c", 25.0), ("sensor-d", 27.0)]:
        store_latest_reading(
            SensorReading(
                node_id=node_id,
                zone_id="zone1",
                moisture_raw=2500,
                moisture_percent=moisture,
                timestamp=datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
            )
        )

    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()
    args.min_zone_sensor_readings = 4

    _zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    event_payloads = [json.loads(payload) for topic, payload, _ in client.messages if topic.endswith("/controller/event")]
    assert event_payloads[0]["moisture_percent"] == 23.5
    assert event_payloads[0]["valid_sensor_count"] == 4
    assert any(topic.endswith("/actuator/command") for topic, _, _ in client.messages)


def test_process_zone_tick_caps_global_quorum_to_expected_sensor_count():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    reading = sample_reading()
    store_latest_reading(reading)
    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()
    args.min_zone_sensor_readings = 4

    _zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    assert any(topic.endswith("/actuator/command") for topic, _, _ in client.messages)


def test_stale_reading_is_not_ready_for_control_with_age_limit():
    reading = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2500,
        moisture_percent=22.0,
        timestamp=datetime(2026, 3, 31, 9, 40, tzinfo=timezone.utc),
    )

    assert not reading_ready_for_control(
        reading,
        now=datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        max_age_seconds=900,
    )


def test_process_zone_tick_skips_stale_reading():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    reading = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2500,
        moisture_percent=22.0,
        timestamp=datetime(2026, 3, 31, 9, 40, tzinfo=timezone.utc),
    )
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
        controller_args(),
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert zone_runtime["last_skip_reason"] == "stale_reading"
    assert states["zone1"].runtime_seconds_today == 0
    assert any(topic.endswith("/controller/skip") for topic, _, _ in client.messages)
    assert not any(topic.endswith("/actuator/command") for topic, _, _ in client.messages)


def test_process_zone_tick_only_publishes_stale_skip_once_per_signature():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    reading = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2500,
        moisture_percent=22.0,
        timestamp=datetime(2026, 3, 31, 9, 40, tzinfo=timezone.utc),
    )
    LATEST_STATE[reading.zone_id] = reading
    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()

    zone_runtime, _states = process_zone_tick(
        zone,
        profile,
        {},
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    process_zone_tick(
        zone,
        profile,
        zone_runtime,
        {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))},
        datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    skip_topics = [topic for topic, _, _ in client.messages if topic.endswith("/controller/skip")]
    assert len(skip_topics) == 1


def test_process_zone_tick_reuses_fresh_reading_after_stale_skip():
    on_message(
        None,
        None,
        SimpleNamespace(
            topic=SYSTEM_CONFIG_TOPIC,
            payload=json.dumps(sample_system_config()).encode("utf-8"),
        ),
    )

    zone = LIVE_ZONES["zone1"]
    profile = LIVE_CROPS[zone.crop_id]
    client = FakeClient()
    args = controller_args()
    states = {"zone1": ZoneState(zone_id="zone1", day=date(2026, 3, 31))}

    stale = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2500,
        moisture_percent=22.0,
        timestamp=datetime(2026, 3, 31, 9, 40, tzinfo=timezone.utc),
    )
    LATEST_STATE[stale.zone_id] = stale

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        {},
        states,
        datetime(2026, 3, 31, 10, 0, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    fresh = SensorReading(
        node_id="sensor-zone1",
        zone_id="zone1",
        moisture_raw=2400,
        moisture_percent=21.0,
        wake_count=2,
        timestamp=datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
    )
    LATEST_STATE[fresh.zone_id] = fresh

    zone_runtime, states = process_zone_tick(
        zone,
        profile,
        zone_runtime,
        states,
        datetime(2026, 3, 31, 10, 1, tzinfo=timezone.utc),
        args,
        client,
        local_tz=timezone(timedelta(hours=-4)),
    )

    assert states["zone1"].runtime_seconds_today == 45
    assert any(topic.endswith("/actuator/command") for topic, _, _ in client.messages)
