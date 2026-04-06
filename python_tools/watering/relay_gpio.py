from __future__ import annotations

from dataclasses import dataclass
import os
import subprocess

from watering.structured_logging import log_event


def env_flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class RelayGPIOConfig:
    gpio_pin: int = 17
    active_low: bool = True

    @classmethod
    def from_env(cls) -> "RelayGPIOConfig":
        return cls(
            gpio_pin=int(os.environ.get("ACTUATOR_GPIO_PIN", "17")),
            active_low=env_flag("ACTUATOR_GPIO_ACTIVE_LOW", True),
        )


def level_for_enabled(*, enabled: bool, active_low: bool) -> str:
    relay_high = enabled if not active_low else not enabled
    return "dh" if relay_high else "dl"


class RelayGPIOController:
    def __init__(self, config: RelayGPIOConfig):
        self._config = config

    @property
    def config(self) -> RelayGPIOConfig:
        return self._config

    def prepare(self) -> None:
        self._run("op")
        self.set_enabled(False)
        log_event(
            "relay_gpio",
            "prepared",
            gpio_pin=self._config.gpio_pin,
            active_low=self._config.active_low,
        )

    def set_enabled(self, enabled: bool) -> None:
        level = level_for_enabled(enabled=enabled, active_low=self._config.active_low)
        self._run("op", level)
        log_event(
            "relay_gpio",
            "set_enabled",
            gpio_pin=self._config.gpio_pin,
            enabled=enabled,
            active_low=self._config.active_low,
            pinctrl_level=level,
        )

    def _run(self, *args: str) -> None:
        subprocess.run(
            ["pinctrl", "set", str(self._config.gpio_pin), *args],
            check=True,
        )
