import json
from types import SimpleNamespace

from watering.controller import (
    CONTROLLER_HEALTH,
    controller_health_snapshot,
    mqtt_reason_code_value,
    serialize_controller_health,
    update_controller_health,
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
