from __future__ import annotations

import argparse
from typing import Callable

from watering.lora_receiver import (
    ExactFrameDeduplicatingPublisher,
    InvalidNodeStateFrameError,
    LoRaReceiverTelemetry,
    MqttConnectionSettings,
    NodeStatePublisher,
    ReconnectingLoRaSerialReader,
    SerialConnectionSettings,
    SerialFrameDecoder,
    ShutdownController,
    build_paho_node_state_publisher,
    build_node_state_publish_request,
    mqtt_connection_settings_from_env,
)
from watering.lora_transmitter import LoRaCommandRouteTarget, LoRaCommandRouter, LoRaCommandTransmitter


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Receive LoRa node-state frames and publish them to MQTT.")
    parser.add_argument("--serial-port", required=True, help="Serial device for the Pi-connected LR22.")
    parser.add_argument("--baudrate", type=int, default=9600)
    parser.add_argument("--serial-timeout-seconds", type=float, default=1.0)
    parser.add_argument("--read-size", type=int, default=256)
    parser.add_argument("--reconnect-delay-seconds", type=float, default=2.0)
    parser.add_argument("--max-frame-size", type=int, default=1024)
    parser.add_argument("--dedup-recent-frames", type=int, default=32)
    parser.add_argument("--mqtt-host")
    parser.add_argument("--mqtt-port", type=int)
    parser.add_argument("--mqtt-username")
    parser.add_argument("--mqtt-password")
    parser.add_argument("--mqtt-max-queued-messages", type=int, default=100)
    return parser


def mqtt_settings_from_args(args: argparse.Namespace) -> MqttConnectionSettings:
    env_settings = mqtt_connection_settings_from_env()
    return MqttConnectionSettings(
        host=args.mqtt_host or env_settings.host,
        port=args.mqtt_port if args.mqtt_port is not None else env_settings.port,
        username=args.mqtt_username if args.mqtt_username is not None else env_settings.username,
        password=args.mqtt_password if args.mqtt_password is not None else env_settings.password,
        max_queued_messages=args.mqtt_max_queued_messages,
    )


def serial_settings_from_args(args: argparse.Namespace) -> SerialConnectionSettings:
    return SerialConnectionSettings(
        port=args.serial_port,
        baudrate=args.baudrate,
        timeout_seconds=args.serial_timeout_seconds,
        read_size=args.read_size,
        reconnect_delay_seconds=args.reconnect_delay_seconds,
    )


def build_deduplicating_publisher(
    args: argparse.Namespace,
    telemetry: LoRaReceiverTelemetry,
    command_route_handler,
) -> NodeStatePublisher:
    return ExactFrameDeduplicatingPublisher(
        build_paho_node_state_publisher(
            mqtt_settings_from_args(args),
            on_mqtt_connected=telemetry.mqtt_connected,
            on_mqtt_disconnected=telemetry.mqtt_disconnected,
            on_lora_command_message=command_route_handler,
            on_lora_command_received=telemetry.lora_command_received,
            on_lora_command_route_result=telemetry.lora_command_route_result,
        ),
        max_recent_frames=args.dedup_recent_frames,
    )


def build_reconnecting_reader(args: argparse.Namespace) -> ReconnectingLoRaSerialReader:
    return ReconnectingLoRaSerialReader(
        serial_settings_from_args(args),
        decoder=SerialFrameDecoder(max_frame_size=args.max_frame_size),
    )


def run_receiver(
    args: argparse.Namespace,
    *,
    shutdown: ShutdownController | None = None,
    telemetry: LoRaReceiverTelemetry | None = None,
    publisher_factory: Callable[[argparse.Namespace, LoRaReceiverTelemetry, Callable], NodeStatePublisher] = (
        build_deduplicating_publisher
    ),
    reader_factory: Callable[[argparse.Namespace], ReconnectingLoRaSerialReader] = build_reconnecting_reader,
) -> None:
    shutdown = shutdown or ShutdownController()
    shutdown.install_signal_handlers()
    telemetry = telemetry or LoRaReceiverTelemetry()
    command_route_target = LoRaCommandRouteTarget()
    publisher: NodeStatePublisher | None = None

    try:
        publisher = publisher_factory(args, telemetry, command_route_target.route_mqtt_command)

        def on_frame(frame: bytes) -> None:
            telemetry.frame_received(frame)
            try:
                request = build_node_state_publish_request(frame)
            except InvalidNodeStateFrameError as exc:
                telemetry.invalid_frame(reason=exc.reason, error=exc)
                return

            telemetry.publish_result(request, publisher.publish_node_state(request))

        def on_serial_ready(port):
            router = LoRaCommandRouter(
                LoRaCommandTransmitter(
                    port,
                    max_frame_size=args.max_frame_size,
                )
            )
            command_route_target.set_router(router)
            return lambda: command_route_target.clear_router(router)

        reader = reader_factory(args)
        reader.run(
            on_frame=on_frame,
            should_stop=shutdown.should_stop,
            on_decode_error=telemetry.decode_error,
            on_serial_connected=telemetry.serial_connected,
            on_serial_disconnected=telemetry.serial_disconnected,
            on_serial_ready=on_serial_ready,
        )
    finally:
        if publisher is not None:
            publisher.close()
        telemetry.shutdown()


def main() -> None:
    args = build_parser().parse_args()
    run_receiver(args)


if __name__ == "__main__":
    main()
