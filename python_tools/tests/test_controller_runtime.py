import json
from types import SimpleNamespace
from unittest.mock import MagicMock, call

from watering.controller import (
    CONTROLLER_HEALTH,
    configure_mqtt_auth,
    controller_health_snapshot,
    mqtt_reason_code_value,
    serialize_controller_health,
    update_controller_health,
    validate_controller_args,
)


def test_mqtt_reason_code_value_handles_numeric_value_objects():
    reason_code = SimpleNamespace(value=0)

    assert mqtt_reason_code_value(reason_code) == 0


def test_mqtt_reason_code_value_falls_back_to_string_for_non_numeric_values():
    class FakeReasonCode:
        value = "Success"

        def __str__(self) -> str:
            return "Success"

    assert mqtt_reason_code_value(FakeReasonCode()) == "Success"


def test_controller_health_defaults_and_updates():
    CONTROLLER_HEALTH.clear()

    snapshot = controller_health_snapshot()
    assert snapshot["status"] == "starting"
    assert snapshot["publisher_connected"] is False
    assert snapshot["subscriber_connected"] is False

    update_controller_health(
        status="ready",
        publisher_connected=True,
        subscriber_connected=True,
        last_decision_zone_id="zone1",
        last_decision_action="water",
    )

    updated = controller_health_snapshot()
    assert updated["status"] == "ready"
    assert updated["publisher_connected"] is True
    assert updated["subscriber_connected"] is True
    assert updated["last_decision_zone_id"] == "zone1"
    assert updated["last_decision_action"] == "water"
    assert updated["updated_at"]


def test_serialize_controller_health_outputs_json_object():
    CONTROLLER_HEALTH.clear()
    update_controller_health(status="degraded", last_error="subscriber_disconnected")

    payload = json.loads(serialize_controller_health(controller_health_snapshot()))

    assert payload["component"] == "controller"
    assert payload["status"] == "degraded"
    assert payload["last_error"] == "subscriber_disconnected"


# --- configure_mqtt_auth ---

def test_configure_mqtt_auth_sets_credentials_when_username_present():
    client = MagicMock()

    configure_mqtt_auth(client, "victory_garden", "secret123")

    client.username_pw_set.assert_called_once_with("victory_garden", "secret123")


def test_configure_mqtt_auth_skips_when_username_is_none():
    client = MagicMock()

    configure_mqtt_auth(client, None, "secret123")

    client.username_pw_set.assert_not_called()


def test_configure_mqtt_auth_skips_when_username_is_empty():
    client = MagicMock()

    configure_mqtt_auth(client, "", "secret123")

    client.username_pw_set.assert_not_called()


def test_configure_mqtt_auth_passes_none_password_when_password_is_empty():
    client = MagicMock()

    configure_mqtt_auth(client, "victory_garden", "")

    client.username_pw_set.assert_called_once_with("victory_garden", None)


# --- MQTT reconnect health transitions ---

def test_publisher_disconnect_marks_health_degraded():
    CONTROLLER_HEALTH.clear()
    update_controller_health(status="ready", publisher_connected=True)

    # Simulate what on_controller_disconnect does
    update_controller_health(
        publisher_connected=False,
        status="degraded",
        last_error="publisher_disconnected",
    )

    snapshot = controller_health_snapshot()
    assert snapshot["status"] == "degraded"
    assert snapshot["publisher_connected"] is False
    assert snapshot["last_error"] == "publisher_disconnected"


def test_publisher_reconnect_clears_error_and_restores_starting():
    CONTROLLER_HEALTH.clear()
    update_controller_health(
        status="degraded",
        publisher_connected=False,
        last_error="publisher_disconnected",
    )

    # Simulate what on_controller_connect does
    update_controller_health(
        publisher_connected=True,
        status="starting",
        last_error=None,
    )

    snapshot = controller_health_snapshot()
    assert snapshot["status"] == "starting"
    assert snapshot["publisher_connected"] is True
    assert snapshot["last_error"] is None


def test_subscriber_disconnect_marks_health_degraded():
    CONTROLLER_HEALTH.clear()
    update_controller_health(status="ready", subscriber_connected=True)

    # Simulate what on_subscriber_disconnect does
    update_controller_health(
        subscriber_connected=False,
        status="degraded",
        last_error="subscriber_disconnected",
    )

    snapshot = controller_health_snapshot()
    assert snapshot["status"] == "degraded"
    assert snapshot["subscriber_connected"] is False
    assert snapshot["last_error"] == "subscriber_disconnected"


def test_health_updated_at_advances_on_each_update():
    CONTROLLER_HEALTH.clear()

    update_controller_health(status="starting")
    t1 = controller_health_snapshot()["updated_at"]

    update_controller_health(status="degraded")
    t2 = controller_health_snapshot()["updated_at"]

    # updated_at is an ISO string — later update should be >= first
    assert t2 >= t1


def test_validate_controller_args_accepts_positive_values():
    args = SimpleNamespace(
        min_zone_sensor_readings=1,
        poll_seconds=1.0,
        startup_timeout_seconds=120,
        max_reading_age_seconds=900,
        min_seconds_between_watering=0,
    )

    validate_controller_args(args)


def test_validate_controller_args_rejects_invalid_numeric_ranges():
    invalid_sets = [
        {"min_zone_sensor_readings": 0, "poll_seconds": 1.0, "startup_timeout_seconds": 120, "max_reading_age_seconds": 900, "min_seconds_between_watering": 0},
        {"min_zone_sensor_readings": 1, "poll_seconds": 0, "startup_timeout_seconds": 120, "max_reading_age_seconds": 900, "min_seconds_between_watering": 0},
        {"min_zone_sensor_readings": 1, "poll_seconds": 1.0, "startup_timeout_seconds": 0, "max_reading_age_seconds": 900, "min_seconds_between_watering": 0},
        {"min_zone_sensor_readings": 1, "poll_seconds": 1.0, "startup_timeout_seconds": 120, "max_reading_age_seconds": -1, "min_seconds_between_watering": 0},
        {"min_zone_sensor_readings": 1, "poll_seconds": 1.0, "startup_timeout_seconds": 120, "max_reading_age_seconds": 900, "min_seconds_between_watering": -1},
    ]

    for invalid in invalid_sets:
        try:
            validate_controller_args(SimpleNamespace(**invalid))
            raised = False
        except ValueError:
            raised = True
        assert raised, invalid
