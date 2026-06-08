from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
import time
from typing import Any

import paho.mqtt.client as mqtt

from watering.config import (
    SystemZoneConfig,
    ZoneConfig,
    load_crops,
    load_zones,
    validate_zone_crop_refs,
)
from watering.controller_cli import build_parser
from watering.controller_mqtt import (
    SYSTEM_CONFIG_TOPIC,
    configure_mqtt_auth,
    effective_zone_configs,
    mqtt_reason_code_value,
    on_message,
    parse_sensor_message,
    profile_for_zone,
    publish_actuator_command,
    publish_event,
    publish_skip,
    set_subscriber_context,
    sync_zone_state_subscriptions,
    update_system_config,
)
from watering.controller_runtime import (
    CANONICAL_NODE_STATE_TOPIC,
    CONTROLLER_HEALTH,
    CONTROLLER_RUNTIME,
    LIVE_CROPS,
    LIVE_ZONES,
    LATEST_STATE,
    LATEST_ZONE_READINGS,
    SUBSCRIBED_STATE_TOPICS,
    ControllerRuntime,
    controller_health_snapshot,
    have_latest_state_for_any,
    iso_now,
    latest_reading,
    latest_readings_for_zone,
    live_config_snapshot,
    load_controller_runtime,
    new_controller_health,
    new_zone_runtime,
    save_controller_runtime,
    serialize_controller_health,
    serialize_controller_runtime,
    store_latest_reading,
    update_controller_health,
    write_text_if_changed,
)
from watering.decision import decide_watering
from watering.profiles import CropProfile
from watering.schemas import SensorReading
from watering.state import ZoneState
from watering.state_store import load_state_store_resilient, serialize_state_store
from watering.structured_logging import log_event


@dataclass(frozen=True)
class ZoneMoistureSnapshot:
    reading: SensorReading
    signature: dict[str, Any]
    valid_sensor_count: int
    expected_sensor_count: int
    valid_node_ids: list[str]
    missing_node_ids: list[str]
    stale_node_ids: list[str]
    null_moisture_node_ids: list[str]


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


def expected_node_ids_for_zone(zone: ZoneConfig | SystemZoneConfig) -> list[str]:
    if isinstance(zone, SystemZoneConfig):
        return sorted({node_id for node_id in zone.node_ids if node_id})
    return [zone.node_id]


def aggregate_signature(
    zone_id: str,
    readings: list[SensorReading],
    moisture_percent: float | None,
) -> dict[str, Any]:
    return {
        "zone_id": zone_id,
        "node_id": "__zone_average__",
        "moisture_percent": round(moisture_percent, 4) if moisture_percent is not None else None,
        "sensor_count": len(readings),
        "readings": [reading_signature(reading) for reading in sorted(readings, key=lambda item: item.node_id)],
    }


def remember_skip(zone_runtime: dict[str, Any], signature: dict[str, Any], reason: str) -> None:
    zone_runtime["last_skip_signature"] = signature
    zone_runtime["last_skip_reason"] = reason


def clear_skip_memory(zone_runtime: dict[str, Any]) -> None:
    zone_runtime["last_skip_signature"] = None
    zone_runtime["last_skip_reason"] = None


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


def reading_age_seconds(reading: SensorReading, now: datetime) -> float:
    return max(0.0, (now - reading.timestamp).total_seconds())


def reading_ready_for_control(
    reading: SensorReading,
    *,
    now: datetime | None = None,
    max_age_seconds: int | None = None,
) -> bool:
    if reading.moisture_percent is None:
        return False
    if max_age_seconds is None or now is None:
        return True
    return reading_age_seconds(reading, now) <= max_age_seconds


def zone_moisture_snapshot(
    zone: ZoneConfig | SystemZoneConfig,
    *,
    now: datetime,
    max_age_seconds: int,
) -> ZoneMoistureSnapshot | None:
    readings_by_node = latest_readings_for_zone(zone.zone_id)
    if not readings_by_node:
        return None

    expected_node_ids = expected_node_ids_for_zone(zone)
    candidate_node_ids = expected_node_ids or sorted(readings_by_node)
    valid_readings: list[SensorReading] = []
    stale_node_ids: list[str] = []
    null_moisture_node_ids: list[str] = []
    missing_node_ids: list[str] = []

    for node_id in candidate_node_ids:
        reading = readings_by_node.get(node_id)
        if reading is None:
            missing_node_ids.append(node_id)
            continue
        if reading.moisture_percent is None:
            null_moisture_node_ids.append(node_id)
            continue
        if not reading_ready_for_control(reading, now=now, max_age_seconds=max_age_seconds):
            stale_node_ids.append(node_id)
            continue
        valid_readings.append(reading)

    signature_readings = [
        reading
        for node_id in candidate_node_ids
        if (reading := readings_by_node.get(node_id)) is not None
    ]
    if not signature_readings:
        signature_readings = list(readings_by_node.values())

    moisture_percent = (
        sum(float(reading.moisture_percent) for reading in valid_readings) / len(valid_readings)
        if valid_readings
        else None
    )
    moisture_raw_source = valid_readings or signature_readings
    moisture_raw = round(sum(reading.moisture_raw for reading in moisture_raw_source) / len(moisture_raw_source))
    timestamp = max((reading.timestamp for reading in moisture_raw_source), default=now)
    aggregate_reading = SensorReading(
        schema_version="zone-moisture-aggregate/v1",
        node_id="__zone_average__",
        zone_id=zone.zone_id,
        timestamp=timestamp,
        moisture_raw=moisture_raw,
        moisture_percent=moisture_percent,
        health="aggregate",
    )
    signature = aggregate_signature(zone.zone_id, signature_readings, moisture_percent)

    return ZoneMoistureSnapshot(
        reading=aggregate_reading,
        signature=signature,
        valid_sensor_count=len(valid_readings),
        expected_sensor_count=len(candidate_node_ids),
        valid_node_ids=sorted(reading.node_id for reading in valid_readings),
        missing_node_ids=sorted(missing_node_ids),
        stale_node_ids=sorted(stale_node_ids),
        null_moisture_node_ids=sorted(null_moisture_node_ids),
    )


def process_zone_tick(
    zone: ZoneConfig | SystemZoneConfig,
    profile: CropProfile,
    zone_runtime: dict[str, Any],
    states: dict[str, ZoneState],
    now: datetime,
    args,
    controller: mqtt.Client,
    local_tz=None,
) -> tuple[dict[str, Any], dict[str, ZoneState]]:
    snapshot = zone_moisture_snapshot(
        zone,
        now=now,
        max_age_seconds=args.max_reading_age_seconds,
    )

    if snapshot is None:
        return zone_runtime, states

    reading = snapshot.reading
    signature = snapshot.signature

    min_zone_sensor_readings = getattr(args, "min_zone_sensor_readings", 1)
    required_sensor_count = min(min_zone_sensor_readings, snapshot.expected_sensor_count)
    if snapshot.valid_sensor_count == 0:
        reason = "insufficient_sensor_quorum"
        if snapshot.stale_node_ids and not snapshot.null_moisture_node_ids:
            reason = "stale_reading"
        elif snapshot.null_moisture_node_ids and not snapshot.stale_node_ids:
            reason = "incomplete-reading"

        if (
            zone_runtime.get("last_skip_reason") == reason and
            signatures_equal(signature, zone_runtime.get("last_skip_signature"))
        ):
            return zone_runtime, states
        log_event(
            "controller",
            "decision_skipped",
            zone_id=zone.zone_id,
            reason=reason,
            valid_sensor_count=snapshot.valid_sensor_count,
            expected_sensor_count=snapshot.expected_sensor_count,
            min_zone_sensor_readings=required_sensor_count,
            valid_node_ids=snapshot.valid_node_ids,
            missing_node_ids=snapshot.missing_node_ids,
            stale_node_ids=snapshot.stale_node_ids,
            null_moisture_node_ids=snapshot.null_moisture_node_ids,
        )
        publish_skip(controller, zone.zone_id, now, reason)
        remember_skip(zone_runtime, signature, reason)
        return zone_runtime, states

    if snapshot.valid_sensor_count < required_sensor_count:
        if (
            zone_runtime.get("last_skip_reason") == "insufficient_sensor_quorum" and
            signatures_equal(signature, zone_runtime.get("last_skip_signature"))
        ):
            return zone_runtime, states
        log_event(
            "controller",
            "decision_skipped",
            zone_id=zone.zone_id,
            reason="insufficient_sensor_quorum",
            valid_sensor_count=snapshot.valid_sensor_count,
            expected_sensor_count=snapshot.expected_sensor_count,
            min_zone_sensor_readings=required_sensor_count,
            valid_node_ids=snapshot.valid_node_ids,
            missing_node_ids=snapshot.missing_node_ids,
            stale_node_ids=snapshot.stale_node_ids,
            null_moisture_node_ids=snapshot.null_moisture_node_ids,
        )
        publish_skip(controller, zone.zone_id, now, "insufficient_sensor_quorum")
        remember_skip(zone_runtime, signature, "insufficient_sensor_quorum")
        return zone_runtime, states

    if not allowed_now(zone, now, local_tz=local_tz):
        if (
            zone_runtime.get("last_skip_reason") == "outside_allowed_hours" and
            signatures_equal(signature, zone_runtime.get("last_skip_signature"))
        ):
            return zone_runtime, states
        log_event(
            "controller",
            "decision_skipped",
            zone_id=zone.zone_id,
            reason="outside_allowed_hours",
        )
        publish_skip(controller, zone.zone_id, now, "outside_allowed_hours")
        remember_skip(zone_runtime, signature, "outside_allowed_hours")
        return zone_runtime, states

    moisture = float(reading.moisture_percent)

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
            if (
                zone_runtime.get("last_skip_reason") == "cooldown" and
                signatures_equal(signature, zone_runtime.get("last_skip_signature"))
            ):
                return zone_runtime, states
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
            remember_skip(zone_runtime, signature, "cooldown")
            states[zone.zone_id] = state
            return zone_runtime, states

    clear_skip_memory(zone_runtime)
    cmd, state = decide_watering(reading, profile, state, now=now)

    if cmd is None:
        log_event(
            "controller",
            "decision_evaluated",
            zone_id=zone.zone_id,
            moisture_percent=moisture,
            valid_sensor_count=snapshot.valid_sensor_count,
            expected_sensor_count=snapshot.expected_sensor_count,
            valid_node_ids=snapshot.valid_node_ids,
            action="none",
            runtime_seconds=0,
            runtime_seconds_today=state.runtime_seconds_today,
        )
        publish_event(
            controller,
            zone.zone_id,
            now,
            moisture,
            "none",
            0,
            state.runtime_seconds_today,
            valid_sensor_count=snapshot.valid_sensor_count,
            expected_sensor_count=snapshot.expected_sensor_count,
            valid_node_ids=snapshot.valid_node_ids,
        )
        update_controller_health(
            last_decision_at=iso_now(),
            last_decision_zone_id=zone.zone_id,
            last_decision_action="none",
            last_error=None,
        )
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
            valid_sensor_count=snapshot.valid_sensor_count,
            expected_sensor_count=snapshot.expected_sensor_count,
            valid_node_ids=snapshot.valid_node_ids,
            action="water",
            runtime_seconds=cmd.runtime_seconds,
            runtime_seconds_today=state.runtime_seconds_today,
            idempotency_key=cmd.idempotency_key,
        )
        publish_event(
            controller,
            zone.zone_id,
            now,
            moisture,
            "water",
            cmd.runtime_seconds,
            state.runtime_seconds_today,
            idempotency_key=cmd.idempotency_key,
            reason=cmd.reason,
            valid_sensor_count=snapshot.valid_sensor_count,
            expected_sensor_count=snapshot.expected_sensor_count,
            valid_node_ids=snapshot.valid_node_ids,
        )
        zone_runtime["last_watering_signature"] = signature
        zone_runtime["last_watering_at"] = now.isoformat().replace("+00:00", "Z")
        update_controller_health(
            last_decision_at=iso_now(),
            last_decision_zone_id=zone.zone_id,
            last_decision_action="water",
            last_error=None,
        )

    states[zone.zone_id] = state
    zone_runtime["last_processed_signature"] = signature
    return zone_runtime, states


class ControllerApp:
    def __init__(self, args, runtime: ControllerRuntime | None = None) -> None:
        self.args = args
        self.runtime = runtime or CONTROLLER_RUNTIME
        self.root = Path(__file__).resolve().parents[1]

        self.fallback_crops = load_crops(self.root / "config" / "crops.yaml")
        self.fallback_zones = load_zones(self.root / "config" / "zones.yaml")
        validate_zone_crop_refs(self.fallback_crops, self.fallback_zones)

        self.zone_filter = self._resolve_zone_filter()
        self.state_path = self.root / "state.json"
        self.states, self.quarantined_state_path, self.state_store_error = load_state_store_resilient(self.state_path)

        self.controller_runtime_path = self.root / "controller_runtime.json"
        self.controller_runtime_data = load_controller_runtime(self.controller_runtime_path)
        self.controller_health_path = self.root / "controller_health.json"
        self.persisted_states = serialize_state_store(self.states)
        self.persisted_runtime = serialize_controller_runtime(self.controller_runtime_data)

        update_controller_health(status="starting")
        self.persisted_health = serialize_controller_health(controller_health_snapshot())

        self.publisher_client: mqtt.Client | None = None
        self.subscriber_client: mqtt.Client | None = None

    def _resolve_zone_filter(self) -> set[str] | None:
        if not self.args.zone_id:
            return None
        if self.args.zone_id not in self.fallback_zones:
            raise ValueError(
                f"Unknown zone_id '{self.args.zone_id}'. Configured zones: {', '.join(self.fallback_zones)}"
            )
        return {self.args.zone_id}

    def _persist_health(self) -> None:
        self.persisted_health = write_text_if_changed(
            self.controller_health_path,
            serialize_controller_health(controller_health_snapshot()),
            self.persisted_health,
        )

    def _persist_runtime_files(self) -> None:
        self.persisted_states = write_text_if_changed(
            self.state_path,
            serialize_state_store(self.states),
            self.persisted_states,
        )
        self.persisted_runtime = write_text_if_changed(
            self.controller_runtime_path,
            serialize_controller_runtime(self.controller_runtime_data),
            self.persisted_runtime,
        )

    def _handle_quarantined_state(self) -> None:
        if self.quarantined_state_path is None:
            return
        log_event(
            "controller",
            "state_store_quarantined",
            level="warning",
            path=str(self.state_path),
            quarantined_path=str(self.quarantined_state_path),
            error=self.state_store_error,
        )
        update_controller_health(
            status="degraded",
            last_error="state_store_quarantined",
        )

    def _initialize_zone_runtime(self) -> None:
        initial_zones = effective_zone_configs(self.fallback_zones, self.zone_filter)
        for zone_id in initial_zones:
            self.controller_runtime_data.setdefault(zone_id, new_zone_runtime())

    def _build_publisher(self) -> mqtt.Client:
        controller = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        configure_mqtt_auth(controller, self.args.mqtt_username, self.args.mqtt_password)
        controller.on_connect = self._on_controller_connect
        controller.on_disconnect = self._on_controller_disconnect
        controller.connect(self.args.mqtt_host, self.args.mqtt_port, 60)
        controller.loop_start()
        return controller

    def _build_subscriber(self) -> mqtt.Client:
        subscriber = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        configure_mqtt_auth(subscriber, self.args.mqtt_username, self.args.mqtt_password)
        subscriber.on_message = on_message
        subscriber.on_connect = self._on_subscriber_connect
        subscriber.on_disconnect = self._on_subscriber_disconnect
        set_subscriber_context(subscriber, self.fallback_zones, self.zone_filter)
        subscriber.connect(self.args.mqtt_host, self.args.mqtt_port, 60)
        subscriber.loop_start()
        return subscriber

    def _on_controller_connect(self, _client: mqtt.Client, _userdata, _flags, reason_code, _properties=None) -> None:
        update_controller_health(
            publisher_connected=True,
            status="starting",
            last_error=None,
        )
        log_event(
            "controller",
            "mqtt_connected",
            role="publisher",
            mqtt_host=self.args.mqtt_host,
            mqtt_port=self.args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
        )

    def _on_controller_disconnect(
        self,
        _client: mqtt.Client,
        _userdata,
        disconnect_flags,
        reason_code,
        _properties=None,
    ) -> None:
        update_controller_health(
            publisher_connected=False,
            status="degraded",
            last_error="publisher_disconnected",
        )
        log_event(
            "controller",
            "mqtt_disconnected",
            level="warning",
            role="publisher",
            mqtt_host=self.args.mqtt_host,
            mqtt_port=self.args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
            disconnect_flags=str(disconnect_flags),
        )

    def _on_subscriber_connect(self, client: mqtt.Client, _userdata, _flags, reason_code, _properties=None) -> None:
        set_subscriber_context(client, self.fallback_zones, self.zone_filter)
        subscribed = []
        client.subscribe(SYSTEM_CONFIG_TOPIC)
        subscribed.append(SYSTEM_CONFIG_TOPIC)
        added_topics, removed_topics = sync_zone_state_subscriptions(reset=True)
        subscribed.extend(added_topics)
        update_controller_health(
            subscriber_connected=True,
            status="waiting_for_state",
            last_error=None,
        )
        log_event(
            "controller",
            "mqtt_connected",
            role="subscriber",
            mqtt_host=self.args.mqtt_host,
            mqtt_port=self.args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
            subscribed_topics=subscribed,
            unsubscribed_topics=removed_topics,
        )

    def _on_subscriber_disconnect(
        self,
        _client: mqtt.Client,
        _userdata,
        disconnect_flags,
        reason_code,
        _properties=None,
    ) -> None:
        update_controller_health(
            subscriber_connected=False,
            status="degraded",
            last_error="subscriber_disconnected",
        )
        log_event(
            "controller",
            "mqtt_disconnected",
            level="warning",
            role="subscriber",
            mqtt_host=self.args.mqtt_host,
            mqtt_port=self.args.mqtt_port,
            reason_code=mqtt_reason_code_value(reason_code),
            disconnect_flags=str(disconnect_flags),
        )

    def _wait_for_startup_state(self) -> None:
        startup_zone_ids = list(effective_zone_configs(self.fallback_zones, self.zone_filter))
        log_event(
            "controller",
            "startup_waiting_for_state",
            zone_ids=startup_zone_ids,
            startup_timeout_seconds=self.args.startup_timeout_seconds,
        )
        update_controller_health(status="waiting_for_state")

        startup_deadline = time.monotonic() + self.args.startup_timeout_seconds
        while True:
            startup_zone_ids = list(effective_zone_configs(self.fallback_zones, self.zone_filter))
            self._persist_health()
            if have_latest_state_for_any(startup_zone_ids):
                break
            if time.monotonic() > startup_deadline:
                update_controller_health(
                    status="error",
                    last_error="startup_timeout",
                )
                self._persist_health()
                log_event(
                    "controller",
                    "startup_timeout",
                    level="error",
                    zone_ids=startup_zone_ids,
                    startup_timeout_seconds=self.args.startup_timeout_seconds,
                    mqtt_host=self.args.mqtt_host,
                    mqtt_port=self.args.mqtt_port,
                )
                raise SystemExit(1)
            time.sleep(self.args.poll_seconds)

        update_controller_health(
            startup_complete=True,
            status="ready",
            last_error=None,
        )

    def _run_loop(self) -> None:
        while True:
            now = datetime.now(timezone.utc)

            active_zones = effective_zone_configs(self.fallback_zones, self.zone_filter)
            for zone_id in active_zones:
                self.controller_runtime_data.setdefault(zone_id, new_zone_runtime())

            assert self.publisher_client is not None
            for zone_id, zone in active_zones.items():
                profile = profile_for_zone(zone, self.fallback_crops)
                zone_runtime = self.controller_runtime_data.setdefault(zone_id, new_zone_runtime())

                updated_runtime, self.states = process_zone_tick(
                    zone,
                    profile,
                    zone_runtime,
                    self.states,
                    now,
                    self.args,
                    self.publisher_client,
                )
                self.controller_runtime_data[zone_id] = updated_runtime

            self._persist_runtime_files()
            health = controller_health_snapshot()
            update_controller_health(
                last_loop_at=iso_now(),
                status="ready" if health.get("publisher_connected") and health.get("subscriber_connected") else "degraded",
            )
            self._persist_health()
            time.sleep(self.args.poll_seconds)

    def run(self) -> None:
        self._handle_quarantined_state()
        self._initialize_zone_runtime()
        self.publisher_client = self._build_publisher()
        self.subscriber_client = self._build_subscriber()

        try:
            self._wait_for_startup_state()
            self._run_loop()
        finally:
            update_controller_health(status="shutdown")
            try:
                self._persist_health()
            except Exception:
                pass
            log_event("controller", "shutdown")
            if self.subscriber_client is not None:
                self.subscriber_client.loop_stop()
                self.subscriber_client.disconnect()
            if self.publisher_client is not None:
                self.publisher_client.loop_stop()
                self.publisher_client.disconnect()


def validate_controller_args(args) -> None:
    if args.min_zone_sensor_readings < 1:
        raise ValueError("--min-zone-sensor-readings must be at least 1.")
    if args.poll_seconds <= 0:
        raise ValueError("--poll-seconds must be greater than 0.")
    if args.startup_timeout_seconds <= 0:
        raise ValueError("--startup-timeout-seconds must be greater than 0.")
    if args.max_reading_age_seconds <= 0:
        raise ValueError("--max-reading-age-seconds must be greater than 0.")
    if args.min_seconds_between_watering < 0:
        raise ValueError("--min-seconds-between-watering must be 0 or greater.")


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        validate_controller_args(args)
    except ValueError as exc:
        print(f"ERROR: {exc}", flush=True)
        raise SystemExit(1)

    try:
        app = ControllerApp(args=args, runtime=CONTROLLER_RUNTIME)
    except ValueError as exc:
        print(f"ERROR: {exc}", flush=True)
        raise SystemExit(1) from exc

    app.run()


__all__ = [
    "CANONICAL_NODE_STATE_TOPIC",
    "CONTROLLER_HEALTH",
    "CONTROLLER_RUNTIME",
    "ControllerApp",
    "ControllerRuntime",
    "LATEST_STATE",
    "LATEST_ZONE_READINGS",
    "LIVE_CROPS",
    "LIVE_ZONES",
    "SYSTEM_CONFIG_TOPIC",
    "SUBSCRIBED_STATE_TOPICS",
    "ZoneMoistureSnapshot",
    "aggregate_signature",
    "allowed_now",
    "build_parser",
    "clear_skip_memory",
    "configure_mqtt_auth",
    "controller_health_snapshot",
    "effective_zone_configs",
    "expected_node_ids_for_zone",
    "have_latest_state_for_any",
    "iso_now",
    "latest_reading",
    "latest_readings_for_zone",
    "live_config_snapshot",
    "load_controller_runtime",
    "main",
    "mqtt_reason_code_value",
    "new_controller_health",
    "new_zone_runtime",
    "on_message",
    "parse_sensor_message",
    "profile_for_zone",
    "publish_actuator_command",
    "publish_event",
    "publish_skip",
    "process_zone_tick",
    "reading_age_seconds",
    "reading_signature",
    "reading_ready_for_control",
    "remember_skip",
    "save_controller_runtime",
    "serialize_controller_health",
    "serialize_controller_runtime",
    "signatures_equal",
    "set_subscriber_context",
    "store_latest_reading",
    "sync_zone_state_subscriptions",
    "update_system_config",
    "update_controller_health",
    "validate_controller_args",
    "write_text_if_changed",
    "zone_moisture_snapshot",
]


if __name__ == "__main__":
    main()
