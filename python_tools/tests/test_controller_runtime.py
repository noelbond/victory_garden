from types import SimpleNamespace

from watering.controller import mqtt_reason_code_value


def test_mqtt_reason_code_value_handles_numeric_value_objects():
    reason_code = SimpleNamespace(value=0)

    assert mqtt_reason_code_value(reason_code) == 0


def test_mqtt_reason_code_value_falls_back_to_string_for_non_numeric_values():
    class FakeReasonCode:
        value = "Success"

        def __str__(self) -> str:
            return "Success"

    assert mqtt_reason_code_value(FakeReasonCode()) == "Success"
