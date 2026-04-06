from watering.relay_gpio import (
    RelayGPIOConfig,
    RelayGPIOController,
    level_for_enabled,
)


def test_level_for_enabled_active_low():
    assert level_for_enabled(enabled=True, active_low=True) == "dl"
    assert level_for_enabled(enabled=False, active_low=True) == "dh"


def test_level_for_enabled_active_high():
    assert level_for_enabled(enabled=True, active_low=False) == "dh"
    assert level_for_enabled(enabled=False, active_low=False) == "dl"


def test_prepare_sets_output_and_inactive(monkeypatch):
    calls: list[list[str]] = []

    def fake_run(cmd, check):
        calls.append(cmd)

    monkeypatch.setattr("watering.relay_gpio.subprocess.run", fake_run)
    controller = RelayGPIOController(RelayGPIOConfig(gpio_pin=17, active_low=True))

    controller.prepare()

    assert calls == [
        ["pinctrl", "set", "17", "op"],
        ["pinctrl", "set", "17", "op", "dh"],
    ]


def test_set_enabled_writes_expected_level(monkeypatch):
    calls: list[list[str]] = []

    def fake_run(cmd, check):
        calls.append(cmd)

    monkeypatch.setattr("watering.relay_gpio.subprocess.run", fake_run)
    controller = RelayGPIOController(RelayGPIOConfig(gpio_pin=17, active_low=True))

    controller.set_enabled(True)
    controller.set_enabled(False)

    assert calls == [
        ["pinctrl", "set", "17", "op", "dl"],
        ["pinctrl", "set", "17", "op", "dh"],
    ]
