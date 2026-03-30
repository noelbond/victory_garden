from __future__ import annotations

import json

from watering.actuator import ActuatorService, parse_actuator_command


class FakeClient:
    def __init__(self):
        self.messages: list[tuple[str, dict]] = []

    def publish(self, topic: str, payload: str) -> None:
        self.messages.append((topic, json.loads(payload)))


class FakeTimer:
    def __init__(self, interval, callback, args=None):
        self.interval = interval
        self.callback = callback
        self.args = args or ()
        self.started = False
        self.cancelled = False

    def start(self):
        self.started = True

    def cancel(self):
        self.cancelled = True


class FakeTimerFactory:
    def __init__(self):
        self.timers: list[FakeTimer] = []

    def __call__(self, interval, callback, args=None):
        timer = FakeTimer(interval, callback, args)
        self.timers.append(timer)
        return timer


class FakeDriver:
    def __init__(self):
        self.calls: list[tuple[str, str, int | None, str]] = []

    def start(self, zone_id: str, runtime_seconds: int, idempotency_key: str) -> None:
        self.calls.append(("start", zone_id, runtime_seconds, idempotency_key))

    def stop(self, zone_id: str, idempotency_key: str) -> None:
        self.calls.append(("stop", zone_id, None, idempotency_key))


def build_service():
    client = FakeClient()
    driver = FakeDriver()
    timer_factory = FakeTimerFactory()
    service = ActuatorService(client=client, driver=driver, timer_factory=timer_factory)
    return service, client, driver, timer_factory


def test_parse_actuator_command_validates_topic_zone_match():
    payload = {
        "command": "start_watering",
        "zone_id": "zone1",
        "runtime_seconds": 45,
        "idempotency_key": "zone1-20260325T120000Z",
    }
    command = parse_actuator_command(
        "greenhouse/zones/zone1/actuator/command",
        json.dumps(payload).encode("utf-8"),
    )
    assert command is not None
    assert command.zone_id == "zone1"


def test_parse_actuator_command_rejects_mismatched_topic_zone():
    payload = {
        "command": "start_watering",
        "zone_id": "zone2",
        "runtime_seconds": 45,
        "idempotency_key": "zone2-20260325T120000Z",
    }
    command = parse_actuator_command(
        "greenhouse/zones/zone1/actuator/command",
        json.dumps(payload).encode("utf-8"),
    )
    assert command is None


def test_start_watering_publishes_ack_and_running_and_schedules_completion():
    service, client, driver, timer_factory = build_service()

    service.handle_command(
        parse_actuator_command(
            "greenhouse/zones/zone1/actuator/command",
            json.dumps(
                {
                    "command": "start_watering",
                    "zone_id": "zone1",
                    "runtime_seconds": 45,
                    "idempotency_key": "zone1-20260325T120000Z",
                }
            ).encode("utf-8"),
        )
    )

    assert driver.calls == [("start", "zone1", 45, "zone1-20260325T120000Z")]
    assert len(timer_factory.timers) == 1
    assert timer_factory.timers[0].started is True
    assert [message["state"] for _, message in client.messages] == ["ACKNOWLEDGED", "RUNNING"]


def test_stop_watering_stops_active_run_and_publishes_stopped():
    service, client, driver, timer_factory = build_service()
    command = parse_actuator_command(
        "greenhouse/zones/zone1/actuator/command",
        json.dumps(
            {
                "command": "start_watering",
                "zone_id": "zone1",
                "runtime_seconds": 45,
                "idempotency_key": "zone1-20260325T120000Z",
            }
        ).encode("utf-8"),
    )
    service.handle_command(command)

    stop_command = parse_actuator_command(
        "greenhouse/zones/zone1/actuator/command",
        json.dumps(
            {
                "command": "stop_watering",
                "zone_id": "zone1",
                "idempotency_key": "zone1-20260325T120010Z",
            }
        ).encode("utf-8"),
    )
    service.handle_command(stop_command)

    assert timer_factory.timers[0].cancelled is True
    assert driver.calls[-1] == ("stop", "zone1", None, "zone1-20260325T120000Z")
    assert client.messages[-1][1]["state"] == "STOPPED"


def test_completion_callback_publishes_completed():
    service, client, driver, timer_factory = build_service()
    command = parse_actuator_command(
        "greenhouse/zones/zone1/actuator/command",
        json.dumps(
            {
                "command": "start_watering",
                "zone_id": "zone1",
                "runtime_seconds": 45,
                "idempotency_key": "zone1-20260325T120000Z",
            }
        ).encode("utf-8"),
    )
    service.handle_command(command)

    timer = timer_factory.timers[0]
    timer.callback(*timer.args)

    assert driver.calls[-1] == ("stop", "zone1", None, "zone1-20260325T120000Z")
    assert client.messages[-1][1]["state"] == "COMPLETED"


def test_duplicate_start_publishes_fault():
    service, client, _driver, _timer_factory = build_service()
    payload = json.dumps(
        {
            "command": "start_watering",
            "zone_id": "zone1",
            "runtime_seconds": 45,
            "idempotency_key": "zone1-20260325T120000Z",
        }
    ).encode("utf-8")

    service.handle_command(parse_actuator_command("greenhouse/zones/zone1/actuator/command", payload))
    service.handle_command(parse_actuator_command("greenhouse/zones/zone1/actuator/command", payload))

    assert client.messages[-1][1]["state"] == "FAULT"
    assert client.messages[-1][1]["fault_code"] == "ALREADY_RUNNING"
