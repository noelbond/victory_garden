from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import argparse
import json
import os
import sys
import threading
import time
from typing import Any

import paho.mqtt.client as mqtt

from watering.config import (
    SystemZoneConfig,
    ZoneConfig,
    load_crops,
    load_system_config_payload,
    load_zones,
    validate_zone_crop_refs,
)
from watering.decision import decide_watering
from watering.profiles import CropProfile
from watering.schemas import SensorReading
from watering.state import ZoneState
from watering.state_store import load_state_store, save_state_store, serialize_state_store
from watering.structured_logging import log_event


LATEST_STATE: dict[str, SensorReading] = {}
LIVE_CROPS: dict[str, CropProfile] = {}
LIVE_ZONES: dict[str, SystemZoneConfig] = {}
SYSTEM_CONFIG_TOPIC = "greenhouse/system/config/current"
LIVE_CONFIG_LOCK = threading.RLock()
LATEST_STATE_LOCK = threading.RLock()
SUBSCRIPTION_LOCK = threading.RLock()
SUBSCRIBED_STATE_TOPICS: set[str] = set()
SUBSCRIBER_CLIENT: mqtt.Client | None = None
SUBSCRIPTION_FALLBACK_ZONES: dict[str, ZoneConfig] = {}
SUBSCRIPTION_ZONE_FILTER: set[str] | None = None


def mqtt_reason_code_value(reason_code) -> int | str:
    value = getattr(reason_code, "value", reason_code)
    if isinstance(value, (int, float)):
        return int(value)
    return str(reason_code)


def new_zone_runtime() -> dict[str, Any]:
    return {
        "last_processed_signature": None,
        "last_watering_signature": None,
        "last_watering_at": None,
    }


def serialize_controller_runtime(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def write_text_if_changed(path: Path, text: str, previous: str | None) -> str:
    if text == previous:
        return previous if previous is not None else text
    path.write_text(text)
    return text


def live_config_snapshot() -> tuple[dict[str, CropProfile], dict[str, SystemZoneConfig]]:
    with LIVE_CONFIG_LOCK:
        return dict(LIVE_CROPS), dict(LIVE_ZONES)


def latest_reading(zone_id: str) -> SensorReading | None:
    with LATEST_STATE_LOCK:
        return LATEST_STATE.get(zone_id)


def have_latest_state_for_any(zone_ids: list[str]) -> bool:
    with LATEST_STATE_LOCK:
        return any(zone_id in LATEST_STATE for zone_id in zone_ids)


def set_subscriber_context(
    client: mqtt.Client,
    fallback_zones: dict[str, ZoneConfig],
    zone_filter: set[str] | None,
) -> None:
    global SUBSCRIBER_CLIENT, SUBSCRIPTION_FALLBACK_ZONES, SUBSCRIPTION_ZONE_FILTER
    with SUBSCRIPTION_LOCK:
        SUBSCRIBER_CLIENT = client
        SUBSCRIPTION_FALLBACK_ZONES = dict(fallback_zones)
        SUBSCRIPTION_ZONE_FILTER = set(zone_filter) if zone_filter is not None else None


def sync_zone_state_subscriptions(reset: bool = False) -> tuple[list[str], list[str]]:
    with SUBSCRIPTION_LOCK:
        client = SUBSCRIBER_CLIENT
        fallback_zones = dict(SUBSCRIPTION_FALLBACK_ZONES)
        zone_filter = set(SUBSCRIPTION_ZONE_FILTER) if SUBSCRIPTION_ZONE_FILTER is not None else None

        if client is None:
            return [], []

        desired_topics = {
            f"greenhouse/zones/{zone_id}/state"
            for zone_id in effective_zone_configs(fallback_zones, zone_filter)
        }

        if reset:
            SUBSCRIBED_STATE_TOPICS.clear()

        new_topics = sorted(desired_topics - SUBSCRIBED_STATE_TOPICS)
        removed_topics = sorted(SUBSCRIBED_STATE_TOPICS - desired_topics)

        for topic in new_topics:
            client.subscribe(topic)
        for topic in removed_topics:
            client.unsubscribe(topic)

        SUBSCRIBED_STATE_TOPICS.difference_update(removed_topics)
        SUBSCRIBED_STATE_TOPICS.update(new_topics)
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


def on_message(client: mqtt.Client, userdata, msg: mqtt.MQTTMessage) -> None:
    if msg.topic == SYSTEM_CONFIG_TOPIC:
        update_system_config(msg.topic, msg.payload)
        return

    reading = parse_sensor_message(msg.topic, msg.payload)
    if reading is not None:
        with LATEST_STATE_LOCK:
            LATEST_STATE[reading.zone_id] = reading


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

    with LIVE_CONFIG_LOCK:
        LIVE_CROPS.clear()
        LIVE_CROPS.update(crops)
        LIVE_ZONES.clear()
        LIVE_ZONES.update(zones)

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
    return True


def reading_signature(reading: SensorReading) -> dict[str, Any]:
    return {
        "zone_id": reading.zone_id,
        "node_id": reading.node_id,
        "wake_count": reading.wake_count,
        "uptime_seconds": reading.uptime_seconds,
        "moisture_raw": reading.moisture_raw,
        "moisture_percent": reading.moisture_percent,
    }


def signatures_equal(a: dict[str, Any] | None, b: dict[str, Any] | None) -> bool:
    return a == b


def load_controller_runtime(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def save_controller_runtime(path: Path, data: dict[str, Any]) -> None:
    path.write_text(serialize_controller_runtime(data))


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


def allowed_now(
    zone: ZoneConfig | SystemZoneConfig,
    now: datetime,
    local_tz=None,
) -> bool:
    allowed_hours = getattr(zone, "allowed_hours", None)
    if allowed_hours is None:
        return True

    start_hour = allowed_hours.start_hour
    end_hour = allowed_hours.end_hour
    localized_now = now.astimezone(local_tz) if now.tzinfo else now
    hour = localized_now.hour

    if start_hour <= end_hour:
        return start_hour <= hour < end_hour

    return hour >= start_hour or hour < end_hour


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
) -> None:
    payload = {
        "zone_id": zone_id,
        "timestamp": now.isoformat(),
        "moisture_percent": moisture,
        "action": action,
        "runtime_seconds": runtime_seconds,
        "runtime_seconds_today": total_today,
        "idempotency_key": idempotency_key,
        "reason": reason,
    }
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


def reading_ready_for_control(reading: SensorReading) -> bool:
    return reading.moisture_percent is not None


def process_zone_tick(
    zone: ZoneConfig | SystemZoneConfig,
    profile: CropProfile,
    zone_runtime: dict[str, Any],
    states: dict[str, ZoneState],
    now: datetime,
    args: argparse.Namespace,
    controller: mqtt.Client,
    local_tz=None,
) -> tuple[dict[str, Any], dict[str, ZoneState]]:
    """Run one control-loop tick for a single zone. Returns updated (zone_runtime, states)."""
    reading = latest_reading(zone.zone_id)

    if reading is None:
        return zone_runtime, states

    if not reading_ready_for_control(reading):
        log_event(
            "controller",
            "decision_skipped",
            zone_id=zone.zone_id,
            reason="incomplete-reading",
            reading=reading,
        )
        return zone_runtime, states

    if not allowed_now(zone, now, local_tz=local_tz):
        log_event(
            "controller",
            "decision_skipped",
            zone_id=zone.zone_id,
            reason="outside_allowed_hours",
        )
        publish_skip(controller, zone.zone_id, now, "outside_allowed_hours")
        zone_runtime["last_processed_signature"] = reading_signature(reading)
        return zone_runtime, states

    moisture = float(reading.moisture_percent)
    signature = reading_signature(reading)

    if signatures_equal(signature, zone_runtime.get("last_processed_signature")):
        log_event(
            "controller",
            "reading_ignored",
            zone_id=zone.zone_id,
            reason="already-processed-signature",
            signature=signature,
        )
        return zone_runtime, states

    state = states.get(zone.zone_id, ZoneState(zone_id=zone.zone_id, day=now.date()))

    if signatures_equal(signature, zone_runtime.get("last_watering_signature")):
        log_event(
            "controller",
            "decision_skipped",
            zone_id=zone.zone_id,
            moisture_percent=moisture,
            reason="same-reading-after-watering",
            signature=signature,
        )
        publish_skip(controller, zone.zone_id, now, "same-reading-after-watering")
        zone_runtime["last_processed_signature"] = signature
        states[zone.zone_id] = state
        return zone_runtime, states

    last_watering_at_raw = zone_runtime.get("last_watering_at")
    if last_watering_at_raw:
        last_watering_at = datetime.fromisoformat(last_watering_at_raw.replace("Z", "+00:00"))
        seconds_since_watering = (now - last_watering_at).total_seconds()
        if seconds_since_watering < args.min_seconds_between_watering:
            remaining = int(args.min_seconds_between_watering - seconds_since_watering)
            log_event(
                "controller",
                "decision_skipped",
                zone_id=zone.zone_id,
                moisture_percent=moisture,
                reason="cooldown",
                remaining_seconds=remaining,
            )
            publish_skip(controller, zone.zone_id, now, "cooldown")
            zone_runtime["last_processed_signature"] = signature
            states[zone.zone_id] = state
            return zone_runtime, states

    cmd, state = decide_watering(reading, profile, state, now=now)

    if cmd is None:
        log_event(
            "controller",
            "decision_evaluated",
            zone_id=zone.zone_id,
            moisture_percent=moisture,
            action="none",
            runtime_seconds=0,
            runtime_seconds_today=state.runtime_seconds_today,
        )
        publish_event(controller, zone.zone_id, now, moisture, "none", 0, state.runtime_seconds_today)
    else:
        publish_actuator_command(
            controller,
            zone.zone_id,
            cmd.runtime_seconds,
            cmd.reason,
            cmd.idempotency_key,
        )
        log_event(
            "controller",
            "decision_evaluated",
            zone_id=zone.zone_id,
            moisture_percent=moisture,
            action="water",
            runtime_seconds=cmd.runtime_seconds,
            runtime_seconds_today=state.runtime_seconds_today,
            idempotency_key=cmd.idempotency_key,
        )
        publish_event(
            controller, zone.zone_id, now, moisture, "water",
            cmd.runtime_seconds, state.runtime_seconds_today,
            idempotency_key=cmd.idempotency_key,
            reason=cmd.reason,
        )
        zone_runtime["last_watering_signature"] = signature
        zone_runtime["last_watering_at"] = now.isoformat().replace("+00:00", "Z")

    states[zone.zone_id] = state
    zone_runtime["last_processed_signature"] = signature
    return zone_runtime, states


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
        "--startup-timeout-seconds",
        type=int,
        default=120,
        help="Seconds to wait for the first MQTT reading before giving up (default: 120).",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]

    fallback_crops = load_crops(root / "config" / "crops.yaml")
    fallback_zones = load_zones(root / "config" / "zones.yaml")
    validate_zone_crop_refs(fallback_crops, fallback_zones)

    if args.zone_id:
        if args.zone_id not in fallback_zones:
            print(
                f"ERROR: Unknown zone_id '{args.zone_id}'. "
                f"Configured zones: {', '.join(fallback_zones)}",
                flush=True,
            )
            sys.exit(1)
        zone_filter = {args.zone_id}
    else:
        zone_filter = None

    state_path = root / "state.json"
    states = load_state_store(state_path)

    controller_runtime_path = root / "controller_runtime.json"
    controller_runtime = load_controller_runtime(controller_runtime_path)

    initial_zones = effective_zone_configs(fallback_zones, zone_filter)
    for zone_id in initial_zones:
        controller_runtime.setdefault(zone_id, new_zone_runtime())
    persisted_states = serialize_state_store(states)
    persisted_runtime = serialize_controller_runtime(controller_runtime)

    controller = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    configure_mqtt_auth(controller, args.mqtt_username, args.mqtt_password)
    def on_controller_connect(_client: mqtt.Client, _userdata, _flags, reason_code, _properties=None) -> None:
        log_event(
            "controller",
            "mqtt_connected",
            role="publisher",
            mqtt_host=args.mqtt_host,
            mqtt_port=args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
        )

    def on_controller_disconnect(_client: mqtt.Client, _userdata, disconnect_flags, reason_code, _properties=None) -> None:
        log_event(
            "controller",
            "mqtt_disconnected",
            level="warning",
            role="publisher",
            mqtt_host=args.mqtt_host,
            mqtt_port=args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
            disconnect_flags=str(disconnect_flags),
        )

    controller.on_connect = on_controller_connect
    controller.on_disconnect = on_controller_disconnect
    controller.connect(args.mqtt_host, args.mqtt_port, 60)
    controller.loop_start()

    subscriber = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    configure_mqtt_auth(subscriber, args.mqtt_username, args.mqtt_password)
    subscriber.on_message = on_message
    set_subscriber_context(subscriber, fallback_zones, zone_filter)
    def on_subscriber_connect(client: mqtt.Client, _userdata, _flags, reason_code, _properties=None) -> None:
        set_subscriber_context(client, fallback_zones, zone_filter)
        subscribed = []
        client.subscribe(SYSTEM_CONFIG_TOPIC)
        subscribed.append(SYSTEM_CONFIG_TOPIC)
        added_topics, removed_topics = sync_zone_state_subscriptions(reset=True)
        subscribed.extend(added_topics)
        log_event(
            "controller",
            "mqtt_connected",
            role="subscriber",
            mqtt_host=args.mqtt_host,
            mqtt_port=args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
            subscribed_topics=subscribed,
            unsubscribed_topics=removed_topics,
        )

    def on_subscriber_disconnect(_client: mqtt.Client, _userdata, disconnect_flags, reason_code, _properties=None) -> None:
        log_event(
            "controller",
            "mqtt_disconnected",
            level="warning",
            role="subscriber",
            mqtt_host=args.mqtt_host,
            mqtt_port=args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
            disconnect_flags=str(disconnect_flags),
        )

    subscriber.on_connect = on_subscriber_connect
    subscriber.on_disconnect = on_subscriber_disconnect
    subscriber.connect(args.mqtt_host, args.mqtt_port, 60)
    subscriber.loop_start()

    log_event(
        "controller",
        "startup_waiting_for_state",
        zone_ids=list(initial_zones),
        startup_timeout_seconds=args.startup_timeout_seconds,
    )

    try:
        startup_deadline = time.monotonic() + args.startup_timeout_seconds
        while True:
            startup_zone_ids = list(effective_zone_configs(fallback_zones, zone_filter))
            if have_latest_state_for_any(startup_zone_ids):
                break
            if time.monotonic() > startup_deadline:
                log_event(
                    "controller",
                    "startup_timeout",
                    level="error",
                    zone_ids=startup_zone_ids,
                    startup_timeout_seconds=args.startup_timeout_seconds,
                    mqtt_host=args.mqtt_host,
                    mqtt_port=args.mqtt_port,
                )
                sys.exit(1)
            time.sleep(args.poll_seconds)

        while True:
            now = datetime.now(timezone.utc)

            active_zones = effective_zone_configs(fallback_zones, zone_filter)
            for zone_id in active_zones:
                controller_runtime.setdefault(zone_id, new_zone_runtime())

            for zone_id, zone in active_zones.items():
                profile = profile_for_zone(zone, fallback_crops)
                zone_runtime = controller_runtime.setdefault(zone_id, new_zone_runtime())

                updated_runtime, states = process_zone_tick(
                    zone, profile, zone_runtime, states, now, args, controller
                )
                controller_runtime[zone_id] = updated_runtime

            persisted_states = write_text_if_changed(
                state_path,
                serialize_state_store(states),
                persisted_states,
            )
            persisted_runtime = write_text_if_changed(
                controller_runtime_path,
                serialize_controller_runtime(controller_runtime),
                persisted_runtime,
            )

            time.sleep(args.poll_seconds)

    finally:
        log_event("controller", "shutdown")
        subscriber.loop_stop()
        subscriber.disconnect()
        controller.loop_stop()
        controller.disconnect()


if __name__ == "__main__":
    main()
