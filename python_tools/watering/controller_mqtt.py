from __future__ import annotations

from datetime import datetime
import json
from typing import Any

import paho.mqtt.client as mqtt

from watering.config import SystemZoneConfig, ZoneConfig, load_system_config_payload
from watering.controller_runtime import (
    CANONICAL_NODE_STATE_TOPIC,
    CONTROLLER_RUNTIME,
    SYSTEM_CONFIG_TOPIC,
    iso_now,
    live_config_snapshot,
    store_latest_reading,
    update_controller_health,
)
from watering.profiles import CropProfile
from watering.schemas import SensorReading
from watering.structured_logging import log_event


def mqtt_reason_code_value(reason_code) -> int | str:
    value = getattr(reason_code, "value", reason_code)
    if isinstance(value, (int, float)):
        return int(value)
    return str(reason_code)


def configure_mqtt_auth(client: mqtt.Client, username: str | None, password: str | None) -> None:
    if username:
        client.username_pw_set(username, password or None)


def effective_zone_configs(
    fallback_zones: dict[str, ZoneConfig],
    zone_filter: set[str] | None = None,
) -> dict[str, ZoneConfig | SystemZoneConfig]:
    live_crops, live_zones = live_config_snapshot()
    if live_zones and live_crops:
        zones = {zone_id: zone for zone_id, zone in live_zones.items() if zone.active}
    else:
        zones = dict(fallback_zones)

    if zone_filter is not None:
        zones = {zone_id: zone for zone_id, zone in zones.items() if zone_id in zone_filter}

    return zones


def profile_for_zone(
    zone: ZoneConfig | SystemZoneConfig,
    fallback_crops: dict[str, CropProfile],
) -> CropProfile:
    live_crops, _ = live_config_snapshot()
    if isinstance(zone, SystemZoneConfig) and zone.crop_id in live_crops:
        return live_crops[zone.crop_id]
    return fallback_crops[zone.crop_id]


def set_subscriber_context(
    client: mqtt.Client,
    fallback_zones: dict[str, ZoneConfig],
    zone_filter: set[str] | None,
) -> None:
    with CONTROLLER_RUNTIME.subscription_lock:
        CONTROLLER_RUNTIME.subscriber_client = client
        CONTROLLER_RUNTIME.subscription_fallback_zones = dict(fallback_zones)
        CONTROLLER_RUNTIME.subscription_zone_filter = set(zone_filter) if zone_filter is not None else None


def sync_zone_state_subscriptions(reset: bool = False) -> tuple[list[str], list[str]]:
    with CONTROLLER_RUNTIME.subscription_lock:
        client = CONTROLLER_RUNTIME.subscriber_client
        fallback_zones = dict(CONTROLLER_RUNTIME.subscription_fallback_zones)
        zone_filter = (
            set(CONTROLLER_RUNTIME.subscription_zone_filter)
            if CONTROLLER_RUNTIME.subscription_zone_filter is not None
            else None
        )

        if client is None:
            return [], []

        desired_topics = {
            CANONICAL_NODE_STATE_TOPIC.format(zone_id=zone_id)
            for zone_id in effective_zone_configs(fallback_zones, zone_filter)
        }

        if reset:
            CONTROLLER_RUNTIME.subscribed_state_topics.clear()

        new_topics = sorted(desired_topics - CONTROLLER_RUNTIME.subscribed_state_topics)
        removed_topics = sorted(CONTROLLER_RUNTIME.subscribed_state_topics - desired_topics)

        for topic in new_topics:
            client.subscribe(topic)
        for topic in removed_topics:
            client.unsubscribe(topic)

        CONTROLLER_RUNTIME.subscribed_state_topics.difference_update(removed_topics)
        CONTROLLER_RUNTIME.subscribed_state_topics.update(new_topics)
        return new_topics, removed_topics


def parse_sensor_message(topic: str, payload_bytes: bytes) -> SensorReading | None:
    try:
        if not payload_bytes:
            log_event(
                "controller",
                "mqtt_message_ignored",
                level="info",
                topic=topic,
                reason="empty_payload",
            )
            return None
        payload = json.loads(payload_bytes.decode("utf-8"))
        if not isinstance(payload, dict):
            log_event(
                "controller",
                "mqtt_message_invalid",
                level="warning",
                topic=topic,
                reason="expected_json_object",
            )
            return None
        return SensorReading.model_validate(payload)
    except Exception as exc:
        log_event(
            "controller",
            "mqtt_message_invalid",
            level="warning",
            topic=topic,
            error=str(exc),
        )
        return None


def update_system_config(topic: str, payload_bytes: bytes) -> bool:
    try:
        if not payload_bytes:
            return False
        payload = json.loads(payload_bytes.decode("utf-8"))
        if not isinstance(payload, dict):
            log_event(
                "controller",
                "system_config_invalid",
                level="warning",
                topic=topic,
                reason="expected_json_object",
            )
            return False

        crops, zones = load_system_config_payload(payload)
    except Exception as exc:
        log_event(
            "controller",
            "system_config_invalid",
            level="warning",
            topic=topic,
            error=str(exc),
        )
        return False

    with CONTROLLER_RUNTIME.live_config_lock:
        CONTROLLER_RUNTIME.live_crops.clear()
        CONTROLLER_RUNTIME.live_crops.update(crops)
        CONTROLLER_RUNTIME.live_zones.clear()
        CONTROLLER_RUNTIME.live_zones.update(zones)

    added_topics, removed_topics = sync_zone_state_subscriptions()

    log_event(
        "controller",
        "system_config_updated",
        crop_count=len(crops),
        zone_count=len(zones),
        subscribed_topics=added_topics,
        unsubscribed_topics=removed_topics,
        topic=topic,
    )
    update_controller_health(
        last_system_config_at=iso_now(),
        last_error=None,
    )
    return True


def on_message(client: mqtt.Client, userdata, msg: mqtt.MQTTMessage) -> None:
    if msg.topic == SYSTEM_CONFIG_TOPIC:
        update_system_config(msg.topic, msg.payload)
        return

    reading = parse_sensor_message(msg.topic, msg.payload)
    if reading is not None:
        store_latest_reading(reading)
        update_controller_health(
            last_sensor_message_at=iso_now(),
            last_sensor_zone_id=reading.zone_id,
            last_error=None,
        )


def publish_event(
    client: mqtt.Client,
    zone_id: str,
    now: datetime,
    moisture: float,
    action: str,
    runtime_seconds: int,
    total_today: int,
    idempotency_key: str | None = None,
    reason: str | None = None,
    valid_sensor_count: int | None = None,
    expected_sensor_count: int | None = None,
    valid_node_ids: list[str] | None = None,
) -> None:
    payload: dict[str, Any] = {
        "zone_id": zone_id,
        "timestamp": now.isoformat(),
        "moisture_percent": moisture,
        "action": action,
        "runtime_seconds": runtime_seconds,
        "runtime_seconds_today": total_today,
        "idempotency_key": idempotency_key,
        "reason": reason,
    }
    if valid_sensor_count is not None:
        payload["valid_sensor_count"] = valid_sensor_count
    if expected_sensor_count is not None:
        payload["expected_sensor_count"] = expected_sensor_count
    if valid_node_ids is not None:
        payload["valid_node_ids"] = valid_node_ids
    client.publish(f"greenhouse/zones/{zone_id}/controller/event", json.dumps(payload))
    client.publish(f"greenhouse/zones/{zone_id}/controller/moisture_percent", str(moisture))
    client.publish(f"greenhouse/zones/{zone_id}/controller/action", action)
    client.publish(f"greenhouse/zones/{zone_id}/controller/runtime_seconds_today", str(total_today))


def publish_skip(
    client: mqtt.Client,
    zone_id: str,
    now: datetime,
    reason: str,
) -> None:
    payload = {
        "zone_id": zone_id,
        "timestamp": now.isoformat(),
        "reason": reason,
    }
    client.publish(f"greenhouse/zones/{zone_id}/controller/skip", json.dumps(payload))
    client.publish(f"greenhouse/zones/{zone_id}/controller/skip_reason", reason)


def publish_actuator_command(
    client: mqtt.Client,
    zone_id: str,
    runtime_seconds: int,
    reason: str,
    idempotency_key: str,
) -> None:
    payload = {
        "command": "start_watering",
        "zone_id": zone_id,
        "runtime_seconds": runtime_seconds,
        "reason": reason,
        "idempotency_key": idempotency_key,
    }
    client.publish(
        f"greenhouse/zones/{zone_id}/actuator/command",
        json.dumps(payload, separators=(",", ":")),
    )
    log_event(
        "controller",
        "actuator_command_published",
        zone_id=zone_id,
        runtime_seconds=runtime_seconds,
        reason=reason,
        idempotency_key=idempotency_key,
    )
