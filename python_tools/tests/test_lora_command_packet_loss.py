import json
from collections import OrderedDict

from tools.lora_receiver import command_message_id_from_publish_request
from watering.lora_receiver import build_lora_frame_publish_request
from watering.lora_transmitter import LoRaCommandRetryController, LoRaCommandRouter, LoRaCommandTransmitter


COMMAND_TOPIC = "greenhouse/nodes/sensor-zone1-ch0/lora/command"


def command_payload(message_id):
    return json.dumps(
        {
            "schema_version": "lora-command/v1",
            "message_id": message_id,
            "timestamp": "2026-09-03T15:00:00Z",
            "source": "rails-server",
            "target_node_id": "sensor-zone1-ch0",
            "command": "request_reading",
            "args": {},
        },
        separators=(",", ":"),
    ).encode("utf-8")


class FakeSerialGatewayStream:
    def __init__(self):
        self.writes = []

    def write(self, data):
        self.writes.append(data)
        return len(data)

    def flush(self):
        pass


class FakeRetryTimer:
    def __init__(self, delay_seconds, callback):
        self.delay_seconds = delay_seconds
        self.callback = callback
        self.cancelled = False

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True

    def fire(self):
        self.callback()


class FakeRetryTimerFactory:
    def __init__(self):
        self.timers = []

    def __call__(self, delay_seconds, callback):
        timer = FakeRetryTimer(delay_seconds, callback)
        self.timers.append(timer)
        return timer


class SessionScopedPico:
    """Models the firmware's bounded in-memory completion cache for one boot."""

    def __init__(self, *, moisture_raw=2345, uptime_seconds=123, completed_command_limit=8):
        self.completed_commands = OrderedDict()
        self.completed_command_limit = completed_command_limit
        self.execution_count = 0
        self.produced_results = []
        self.moisture_raw = moisture_raw
        self.uptime_seconds = uptime_seconds

    def receive(self, newline_delimited_frame):
        command = json.loads(newline_delimited_frame.rstrip(b"\n").decode("utf-8"))
        key = (command["mid"], command["n"], command["sq"])
        if key in self.completed_commands:
            return None

        self.execution_count += 1
        result = json.dumps(
            {
                "t": "state",
                "z": "zone1",
                "n": command["n"],
                "mid": command["mid"],
                "mr": self.moisture_raw,
                "mp": 55,
                "sq": command["sq"],
                "up": self.uptime_seconds,
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.produced_results.append(result)
        self.completed_commands[key] = None
        while len(self.completed_commands) > self.completed_command_limit:
            self.completed_commands.popitem(last=False)
        return result


def build_gateway(retry_results):
    stream = FakeSerialGatewayStream()
    timers = FakeRetryTimerFactory()
    router = LoRaCommandRouter(LoRaCommandTransmitter(stream, initial_sequence=17))
    controller = LoRaCommandRetryController(
        router.route_mqtt_command,
        max_attempts=3,
        retry_delay_seconds=6.0,
        timer_factory=timers,
        on_retry_result=retry_results.append,
    )
    return stream, timers, controller


def command_frame(frame):
    return json.loads(frame.rstrip(b"\n").decode("utf-8"))


def test_dropped_initial_command_retries_same_frame_then_completes_once():
    message_id = "packet-loss-command-a"
    retry_results = []
    stream, timers, controller = build_gateway(retry_results)
    pico = SessionScopedPico()

    initial_result = controller.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    initial_frame = stream.writes[-1]

    # Fault injection: do not deliver initial_frame to Pico.
    timers.timers[0].fire()
    retry_frame = stream.writes[-1]
    pico_result = pico.receive(retry_frame)

    assert initial_result.accepted is True
    assert len(stream.writes) == 2
    assert [timer.delay_seconds for timer in timers.timers] == [6.0, 6.0]
    assert retry_frame == initial_frame
    assert command_frame(initial_frame) == {
        "t": "cmd", "c": "rr", "n": "sensor-zone1-ch0", "mid": message_id, "sq": 17
    }
    assert pico.execution_count == 1
    assert pico.produced_results == [pico_result]

    publish_request = build_lora_frame_publish_request(pico_result)
    assert command_message_id_from_publish_request(publish_request) == message_id
    controller.mark_command_completed(message_id)

    assert retry_results == [initial_result]
    assert len(timers.timers) == 2
    assert timers.timers[1].cancelled is True
    timers.timers[1].fire()
    assert len(stream.writes) == 2


def test_all_dropped_commands_exhaust_retries_without_pico_execution():
    message_id = "packet-loss-command-a-all-dropped"
    retry_results = []
    stream, timers, controller = build_gateway(retry_results)

    controller.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    timers.timers[0].fire()
    timers.timers[1].fire()

    assert len(stream.writes) == 3
    assert stream.writes[0] == stream.writes[1] == stream.writes[2]
    assert command_frame(stream.writes[0])["mid"] == message_id
    assert command_frame(stream.writes[0])["sq"] == 17
    assert retry_results[-1].accepted is False
    assert retry_results[-1].reason == "retry_exhausted"
    assert retry_results[-1].message_id == message_id


def test_dropped_results_do_not_repeat_pico_execution_within_session():
    message_id = "packet-loss-command-b"
    retry_results = []
    stream, timers, controller = build_gateway(retry_results)
    pico = SessionScopedPico()

    controller.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    dropped_result = pico.receive(stream.writes[-1])

    # Fault injection: do not pass the result to the gateway.
    timers.timers[0].fire()
    assert pico.receive(stream.writes[-1]) is None
    timers.timers[1].fire()
    assert pico.receive(stream.writes[-1]) is None

    assert dropped_result is not None
    assert pico.execution_count == 1
    assert len(pico.produced_results) == 1
    assert len(stream.writes) == 3
    assert stream.writes[0] == stream.writes[1] == stream.writes[2]
    assert command_frame(stream.writes[0])["mid"] == message_id
    assert command_frame(stream.writes[0])["sq"] == 17
    assert retry_results[-1].accepted is False
    assert retry_results[-1].reason == "retry_exhausted"
    assert retry_results[-1].message_id == message_id


def test_gateway_restart_discards_pending_retry_without_replaying_nonretained_command():
    message_id = "gateway-restart-no-result"
    old_stream, old_timers, old_gateway = build_gateway([])

    old_gateway.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    assert len(old_stream.writes) == 1

    # Process shutdown cancels and clears process-local retry state.
    old_gateway.close()
    assert old_timers.timers[0].cancelled is True
    old_timers.timers[0].fire()
    assert len(old_stream.writes) == 1

    # A new process has neither a pending retry nor a retained command to replay.
    new_stream, new_timers, new_gateway = build_gateway([])
    assert new_stream.writes == []
    assert new_timers.timers == []
    new_gateway.close()


def test_restarted_gateway_accepts_a_late_correlated_result_without_old_retry_state():
    message_id = "gateway-restart-result-before-timeout"
    _old_stream, _old_timers, old_gateway = build_gateway([])
    old_gateway.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    old_gateway.close()

    new_stream, new_timers, new_gateway = build_gateway([])
    result_frame = json.dumps(
        {
            "t": "state",
            "z": "zone1",
            "n": "sensor-zone1-ch0",
            "mid": message_id,
            "mr": 2345,
            "mp": 55,
            "sq": 17,
            "up": 123,
        },
        separators=(",", ":"),
    ).encode("utf-8")

    publish_request = build_lora_frame_publish_request(result_frame)

    assert command_message_id_from_publish_request(publish_request) == message_id
    assert publish_request.topic == "greenhouse/zones/zone1/nodes/sensor-zone1-ch0/state"
    assert new_stream.writes == []
    assert new_timers.timers == []
    new_gateway.close()


def test_pico_restart_before_execution_accepts_identical_retry_in_new_session():
    message_id = "pico-restart-before-execution"
    stream, timers, gateway = build_gateway([])
    pico_before_restart = SessionScopedPico()

    gateway.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    initial_frame = stream.writes[-1]
    # Fault injection: Pico restarts before the initial frame is dispatched.
    assert pico_before_restart.execution_count == 0
    pico_after_restart = SessionScopedPico(uptime_seconds=4)
    timers.timers[0].fire()
    retry_frame = stream.writes[-1]
    result = pico_after_restart.receive(retry_frame)

    assert retry_frame == initial_frame
    assert command_frame(retry_frame)["mid"] == message_id
    assert command_frame(retry_frame)["sq"] == 17
    assert pico_after_restart.execution_count == 1
    assert command_message_id_from_publish_request(build_lora_frame_publish_request(result)) == message_id
    gateway.mark_command_completed(message_id)
    assert timers.timers[1].cancelled is True


def test_pico_restart_after_execution_permits_second_observational_reading():
    message_id = "pico-restart-after-execution"
    stream, timers, gateway = build_gateway([])
    pico_before_restart = SessionScopedPico(moisture_raw=2345, uptime_seconds=123)

    gateway.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    initial_frame = stream.writes[-1]
    first_result = pico_before_restart.receive(initial_frame)
    # Fault injection: the first result is lost, then the Pico reboots.
    pico_after_restart = SessionScopedPico(moisture_raw=2346, uptime_seconds=4)
    timers.timers[0].fire()
    retry_frame = stream.writes[-1]
    second_result = pico_after_restart.receive(retry_frame)

    assert retry_frame == initial_frame
    assert command_frame(retry_frame)["mid"] == message_id
    assert command_frame(retry_frame)["sq"] == 17
    assert pico_before_restart.execution_count == 1
    assert pico_after_restart.execution_count == 1
    assert first_result != second_result
    assert command_message_id_from_publish_request(build_lora_frame_publish_request(first_result)) == message_id
    assert command_message_id_from_publish_request(build_lora_frame_publish_request(second_result)) == message_id


def test_pico_completion_cache_is_bounded_within_one_session():
    pico = SessionScopedPico(completed_command_limit=8)
    first_frame = None

    for sequence in range(1, 10):
        frame = json.dumps(
            {
                "t": "cmd",
                "c": "rr",
                "n": "sensor-zone1-ch0",
                "mid": f"bounded-cache-{sequence}",
                "sq": sequence,
            },
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        first_frame = first_frame or frame
        assert pico.receive(frame) is not None

    # Production retains eight completions; an older entry may execute again
    # in the same boot after enough other commands evict it.
    assert pico.receive(first_frame) is not None
    assert pico.execution_count == 10


def test_command_delayed_past_server_timeout_is_still_accepted_by_pico():
    message_id = "delayed-command-after-timeout"
    retry_results = []
    stream, timers, gateway = build_gateway(retry_results)
    pico = SessionScopedPico()

    gateway.route_mqtt_command(COMMAND_TOPIC, command_payload(message_id))
    delayed_frame = stream.writes[0]
    timers.timers[0].fire()
    timers.timers[1].fire()

    # The three gateway attempts have exhausted before Rails' 30-second guardrail.
    assert len(stream.writes) == 3
    assert stream.writes[0] == stream.writes[1] == stream.writes[2]
    assert retry_results[-1].reason == "retry_exhausted"

    # A radio-delayed copy arrives only after the server command has timed out.
    result = pico.receive(delayed_frame)
    assert command_frame(delayed_frame) == {
        "t": "cmd", "c": "rr", "n": "sensor-zone1-ch0", "mid": message_id, "sq": 17
    }
    assert "timestamp" not in command_frame(delayed_frame)
    assert pico.execution_count == 1
    assert command_message_id_from_publish_request(build_lora_frame_publish_request(result)) == message_id
    assert len(stream.writes) == 3
