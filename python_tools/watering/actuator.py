from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import argparse
import json
import os
import shlex
import subprocess
import threading
import time
from typing import Protocol

import paho.mqtt.client as mqtt

from watering.schemas import ActuatorState, ActuatorStatus, HubCommand, WaterCommand


def utcnow() -> datetime:
    return datetime.now(tz=timezone.utc)


def parse_actuator_command(topic: str, payload_bytes: bytes) -> WaterCommand | None:
    if not payload_bytes:
        return None

    try:
        payload = json.loads(payload_bytes.decode("utf-8"))
    except Exception as exc:
        print(f"Failed to parse actuator command on {topic}: {exc}", flush=True)
        return None

    if not isinstance(payload, dict):
        print(f"Failed to parse actuator command on {topic}: expected JSON object payload", flush=True)
        return None

    try:
        command = WaterCommand.model_validate(payload)
    except Exception as exc:
        print(f"Failed to validate actuator command on {topic}: {exc}", flush=True)
        return None

    topic_zone_id = zone_id_from_topic(topic)
    if topic_zone_id and topic_zone_id != command.zone_id:
        print(
            f"Failed to validate actuator command on {topic}: "
            f"payload zone_id={command.zone_id} does not match topic zone_id={topic_zone_id}",
            flush=True,
        )
        return None

    return command


def zone_id_from_topic(topic: str) -> str | None:
    parts = topic.split("/")
    if len(parts) >= 5 and parts[0] == "greenhouse" and parts[1] == "zones":
        return parts[2]
    return None


class ActuatorDriver(Protocol):
    def start(self, zone_id: str, runtime_seconds: int, idempotency_key: str) -> None: ...

    def stop(self, zone_id: str, idempotency_key: str) -> None: ...


class MockActuatorDriver:
    def start(self, zone_id: str, runtime_seconds: int, idempotency_key: str) -> None:
        return None

    def stop(self, zone_id: str, idempotency_key: str) -> None:
        return None


class ShellHookActuatorDriver:
    def __init__(self, hook_command: str):
        if not hook_command.strip():
            raise ValueError("ACTUATOR_HOOK_COMMAND is required for shell driver")
        self._base_command = shlex.split(hook_command)

    def start(self, zone_id: str, runtime_seconds: int, idempotency_key: str) -> None:
        self._run("start", zone_id, runtime_seconds, idempotency_key)

    def stop(self, zone_id: str, idempotency_key: str) -> None:
        self._run("stop", zone_id, None, idempotency_key)

    def _run(
        self,
        action: str,
        zone_id: str,
        runtime_seconds: int | None,
        idempotency_key: str,
    ) -> None:
        runtime_arg = "" if runtime_seconds is None else str(runtime_seconds)
        subprocess.run(
            [*self._base_command, action, zone_id, runtime_arg, idempotency_key],
            check=True,
        )


@dataclass
class ActiveRun:
    zone_id: str
    idempotency_key: str
    started_monotonic: float
    runtime_seconds: int
    timer: threading.Timer


class ActuatorService:
    def __init__(
        self,
        client: mqtt.Client,
        driver: ActuatorDriver,
        status_topic_template: str = "greenhouse/zones/{zone_id}/actuator/status",
        timer_factory=threading.Timer,
    ):
        self._client = client
        self._driver = driver
        self._status_topic_template = status_topic_template
        self._timer_factory = timer_factory
        self._active_runs: dict[str, ActiveRun] = {}
        self._lock = threading.Lock()

    def handle_message(self, topic: str, payload_bytes: bytes) -> None:
        command = parse_actuator_command(topic, payload_bytes)
        if command is None:
            return
        self.handle_command(command)

    def handle_command(self, command: WaterCommand) -> None:
        if command.command == HubCommand.START_WATER:
            self._start(command)
        elif command.command == HubCommand.STOP_WATER:
            self._stop(command)

    def shutdown(self) -> None:
        with self._lock:
            runs = list(self._active_runs.values())
            self._active_runs.clear()
        for run in runs:
            run.timer.cancel()
            try:
                self._driver.stop(run.zone_id, run.idempotency_key)
            except Exception:
                pass

    def _start(self, command: WaterCommand) -> None:
        runtime_seconds = int(command.runtime_seconds or 0)
        if runtime_seconds <= 0:
            self._publish_fault(command.zone_id, command.idempotency_key, "INVALID_RUNTIME", "runtime_seconds must be > 0")
            return

        with self._lock:
            if command.zone_id in self._active_runs:
                self._publish_fault(
                    command.zone_id,
                    command.idempotency_key,
                    "ALREADY_RUNNING",
                    f"zone {command.zone_id} is already watering",
                )
                return

            self._publish_status(
                zone_id=command.zone_id,
                state=ActuatorState.ACKNOWLEDGED,
                idempotency_key=command.idempotency_key,
            )

            try:
                self._driver.start(command.zone_id, runtime_seconds, command.idempotency_key)
            except Exception as exc:
                self._publish_fault(command.zone_id, command.idempotency_key, "START_FAILED", str(exc))
                return

            timer = self._timer_factory(
                runtime_seconds,
                self._complete_run,
                args=(command.zone_id, command.idempotency_key),
            )
            timer.daemon = True
            active_run = ActiveRun(
                zone_id=command.zone_id,
                idempotency_key=command.idempotency_key,
                started_monotonic=time.monotonic(),
                runtime_seconds=runtime_seconds,
                timer=timer,
            )
            self._active_runs[command.zone_id] = active_run
            timer.start()

        self._publish_status(
            zone_id=command.zone_id,
            state=ActuatorState.RUNNING,
            idempotency_key=command.idempotency_key,
            actual_runtime_seconds=0,
        )

    def _stop(self, command: WaterCommand) -> None:
        with self._lock:
            active_run = self._active_runs.pop(command.zone_id, None)

        if active_run is None:
            self._publish_status(
                zone_id=command.zone_id,
                state=ActuatorState.STOPPED,
                idempotency_key=command.idempotency_key,
                actual_runtime_seconds=0,
            )
            return

        active_run.timer.cancel()
        actual_runtime = max(0, int(time.monotonic() - active_run.started_monotonic))

        try:
            self._driver.stop(command.zone_id, active_run.idempotency_key)
        except Exception as exc:
            self._publish_fault(command.zone_id, command.idempotency_key, "STOP_FAILED", str(exc))
            return

        self._publish_status(
            zone_id=command.zone_id,
            state=ActuatorState.STOPPED,
            idempotency_key=active_run.idempotency_key,
            actual_runtime_seconds=actual_runtime,
        )

    def _complete_run(self, zone_id: str, idempotency_key: str) -> None:
        with self._lock:
            active_run = self._active_runs.get(zone_id)
            if active_run is None or active_run.idempotency_key != idempotency_key:
                return
            self._active_runs.pop(zone_id, None)

        try:
            self._driver.stop(zone_id, idempotency_key)
        except Exception as exc:
            self._publish_fault(zone_id, idempotency_key, "COMPLETE_STOP_FAILED", str(exc))
            return

        self._publish_status(
            zone_id=zone_id,
            state=ActuatorState.COMPLETED,
            idempotency_key=idempotency_key,
            actual_runtime_seconds=active_run.runtime_seconds,
        )

    def _publish_fault(self, zone_id: str, idempotency_key: str, fault_code: str, detail: str) -> None:
        self._publish_status(
            zone_id=zone_id,
            state=ActuatorState.FAULT,
            idempotency_key=idempotency_key,
            fault_code=fault_code,
            fault_detail=detail[:300],
        )

    def _publish_status(
        self,
        *,
        zone_id: str,
        state: ActuatorState,
        idempotency_key: str | None = None,
        actual_runtime_seconds: int | None = None,
        flow_ml: int | None = None,
        fault_code: str | None = None,
        fault_detail: str | None = None,
    ) -> None:
        status = ActuatorStatus(
            zone_id=zone_id,
            state=state,
            timestamp=utcnow(),
            idempotency_key=idempotency_key,
            actual_runtime_seconds=actual_runtime_seconds,
            flow_ml=flow_ml,
            fault_code=fault_code,
            fault_detail=fault_detail,
        )
        topic = self._status_topic_template.replace("{zone_id}", zone_id)
        self._client.publish(topic, status.model_dump_json())


def build_driver() -> ActuatorDriver:
    driver_name = os.environ.get("ACTUATOR_DRIVER", "mock").strip().lower()
    if driver_name == "mock":
        return MockActuatorDriver()
    if driver_name == "shell":
        return ShellHookActuatorDriver(os.environ.get("ACTUATOR_HOOK_COMMAND", ""))
    raise ValueError(f"Unsupported ACTUATOR_DRIVER: {driver_name}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Victory Garden actuator service.")
    parser.add_argument("--mqtt-host", default=os.environ.get("MQTT_HOST", "127.0.0.1"))
    parser.add_argument("--mqtt-port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    parser.add_argument(
        "--command-topic",
        default=os.environ.get("MQTT_ACTUATOR_COMMAND_TOPIC", "greenhouse/zones/+/actuator/command"),
    )
    parser.add_argument(
        "--status-topic-template",
        default=os.environ.get("MQTT_ACTUATOR_STATUS_TOPIC", "greenhouse/zones/{zone_id}/actuator/status"),
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    service = ActuatorService(
        client=client,
        driver=build_driver(),
        status_topic_template=args.status_topic_template,
    )

    def on_message(_client: mqtt.Client, _userdata, msg: mqtt.MQTTMessage) -> None:
        service.handle_message(msg.topic, msg.payload)

    client.on_message = on_message
    client.connect(args.mqtt_host, args.mqtt_port, 60)
    client.subscribe(args.command_topic)
    client.loop_start()
    print(f"Actuator subscribed to {args.command_topic}", flush=True)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        service.shutdown()
        client.loop_stop()
        client.disconnect()
