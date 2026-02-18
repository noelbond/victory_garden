from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from watering.schemas import (
    ActuatorState,
    ActuatorStatus,
    HubCommand,
    SensorReading,
    WaterCommand,
)


class TestSensorReading:
    def test_valid_sensor_reading(self):
        reading = SensorReading(
            node_id="sensor-gh1-zone1",
            zone_id="zone1",
            moisture_raw=1820,
            moisture_percent=31.4,
            battery_voltage=3.78,
            rssi=-67,
        )
        assert reading.node_id == "sensor-gh1-zone1"
        assert reading.zone_id == "zone1"
        assert reading.moisture_raw == 1820
        assert reading.moisture_percent == 31.4
        assert reading.battery_voltage == 3.78
        assert reading.rssi == -67
        assert isinstance(reading.timestamp, datetime)

    def test_sensor_reading_minimal(self):
        reading = SensorReading(
            node_id="sensor-1",
            zone_id="z1",
            moisture_raw=2000,
        )
        assert reading.moisture_percent is None
        assert reading.battery_voltage is None
        assert reading.rssi is None

    def test_sensor_reading_timestamp_auto_generated(self):
        reading1 = SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000)
        reading2 = SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000)
        # Timestamps should be close but might differ slightly
        assert abs((reading1.timestamp - reading2.timestamp).total_seconds()) < 1

    def test_sensor_reading_empty_node_id_fails(self):
        with pytest.raises(ValidationError) as exc:
            SensorReading(node_id="", zone_id="z1", moisture_raw=1000)
        assert "node_id" in str(exc.value)

    def test_sensor_reading_empty_zone_id_fails(self):
        with pytest.raises(ValidationError) as exc:
            SensorReading(node_id="s1", zone_id="", moisture_raw=1000)
        assert "zone_id" in str(exc.value)

    def test_sensor_reading_moisture_raw_out_of_range(self):
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=-1)
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=65536)

    def test_sensor_reading_moisture_percent_out_of_range(self):
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000, moisture_percent=-0.1)
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000, moisture_percent=100.1)

    def test_sensor_reading_battery_voltage_out_of_range(self):
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000, battery_voltage=-0.1)
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000, battery_voltage=10.1)

    def test_sensor_reading_rssi_out_of_range(self):
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000, rssi=-131)
        with pytest.raises(ValidationError):
            SensorReading(node_id="s1", zone_id="z1", moisture_raw=1000, rssi=1)

    def test_sensor_reading_extra_field_forbidden(self):
        with pytest.raises(ValidationError) as exc:
            SensorReading(
                node_id="s1",
                zone_id="z1",
                moisture_raw=1000,
                extra_field="not_allowed",
            )
        assert "extra_field" in str(exc.value).lower()

    def test_sensor_reading_boundary_values(self):
        # Test exact boundaries
        reading = SensorReading(
            node_id="s1",
            zone_id="z1",
            moisture_raw=0,
            moisture_percent=0.0,
            battery_voltage=0.0,
            rssi=-130,
        )
        assert reading.moisture_raw == 0
        assert reading.moisture_percent == 0.0

        reading = SensorReading(
            node_id="s1",
            zone_id="z1",
            moisture_raw=65535,
            moisture_percent=100.0,
            battery_voltage=10.0,
            rssi=0,
        )
        assert reading.moisture_raw == 65535
        assert reading.moisture_percent == 100.0


class TestWaterCommand:
    def test_valid_water_command_start(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        cmd = WaterCommand(
            command=HubCommand.START_WATER,
            zone_id="zone1",
            runtime_seconds=45,
            reason="below_dry_threshold",
            issued_at=now,
            idempotency_key="zone1-20260206T120000Z",
        )
        assert cmd.command == HubCommand.START_WATER
        assert cmd.zone_id == "zone1"
        assert cmd.runtime_seconds == 45
        assert cmd.reason == "below_dry_threshold"
        assert cmd.idempotency_key == "zone1-20260206T120000Z"

    def test_valid_water_command_stop(self):
        cmd = WaterCommand(
            command=HubCommand.STOP_WATER,
            zone_id="zone1",
            runtime_seconds=None,
            idempotency_key="zone1-stop-001",
        )
        assert cmd.command == HubCommand.STOP_WATER
        assert cmd.runtime_seconds is None
        assert cmd.reason is None

    def test_water_command_issued_at_auto_generated(self):
        cmd1 = WaterCommand(
            command=HubCommand.START_WATER,
            zone_id="z1",
            runtime_seconds=45,
            idempotency_key="key12345",
        )
        cmd2 = WaterCommand(
            command=HubCommand.STOP_WATER,
            zone_id="z1",
            runtime_seconds=None,
            idempotency_key="key12345",
        )
        assert abs((cmd1.issued_at - cmd2.issued_at).total_seconds()) < 1

    def test_water_command_empty_zone_id_fails(self):
        with pytest.raises(ValidationError):
            WaterCommand(
                command=HubCommand.START_WATER,
                zone_id="",
                idempotency_key="key1",
            )

    def test_water_command_short_idempotency_key_fails(self):
        with pytest.raises(ValidationError):
            WaterCommand(
                command=HubCommand.START_WATER,
                zone_id="z1",
                idempotency_key="short",
            )

    def test_water_command_runtime_seconds_out_of_range(self):
        with pytest.raises(ValidationError):
            WaterCommand(
                command=HubCommand.START_WATER,
                zone_id="z1",
                runtime_seconds=-1,
                idempotency_key="key12345",
            )
        with pytest.raises(ValidationError):
            WaterCommand(
                command=HubCommand.START_WATER,
                zone_id="z1",
                runtime_seconds=3601,
                idempotency_key="key12345",
            )

    def test_water_command_reason_too_long(self):
        with pytest.raises(ValidationError):
            WaterCommand(
                command=HubCommand.START_WATER,
                zone_id="z1",
                reason="x" * 201,
                idempotency_key="key12345",
            )

    def test_water_command_extra_field_forbidden(self):
        with pytest.raises(ValidationError):
            WaterCommand(
                command=HubCommand.START_WATER,
                zone_id="z1",
                idempotency_key="key12345",
                extra_field="not_allowed",
            )

    def test_water_command_boundary_values(self):
        cmd = WaterCommand(
            command=HubCommand.START_WATER,
            zone_id="z1",
            runtime_seconds=0,
            idempotency_key="12345678",
        )
        assert cmd.runtime_seconds == 0

        cmd = WaterCommand(
            command=HubCommand.START_WATER,
            zone_id="z1",
            runtime_seconds=3600,
            idempotency_key="12345678",
        )
        assert cmd.runtime_seconds == 3600


class TestActuatorStatus:
    def test_valid_actuator_status_running(self):
        now = datetime(2026, 2, 6, 12, 0, tzinfo=timezone.utc)
        status = ActuatorStatus(
            zone_id="zone1",
            state=ActuatorState.RUNNING,
            timestamp=now,
            idempotency_key="zone1-20260206T120000Z",
            actual_runtime_seconds=10,
            flow_ml=250,
        )
        assert status.zone_id == "zone1"
        assert status.state == ActuatorState.RUNNING
        assert status.actual_runtime_seconds == 10
        assert status.flow_ml == 250

    def test_actuator_status_minimal(self):
        status = ActuatorStatus(
            zone_id="z1",
            state=ActuatorState.ACKNOWLEDGED,
        )
        assert status.idempotency_key is None
        assert status.actual_runtime_seconds is None
        assert status.flow_ml is None
        assert status.fault_code is None
        assert status.fault_detail is None

    def test_actuator_status_with_fault(self):
        status = ActuatorStatus(
            zone_id="z1",
            state=ActuatorState.FAULT,
            fault_code="NO_FLOW",
            fault_detail="Flow sensor detected no water movement after valve opened",
        )
        assert status.state == ActuatorState.FAULT
        assert status.fault_code == "NO_FLOW"
        assert "Flow sensor" in status.fault_detail

    def test_actuator_status_empty_zone_id_fails(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(zone_id="", state=ActuatorState.RUNNING)

    def test_actuator_status_short_idempotency_key_fails(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.RUNNING,
                idempotency_key="short",
            )

    def test_actuator_status_runtime_out_of_range(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.COMPLETED,
                actual_runtime_seconds=-1,
            )
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.COMPLETED,
                actual_runtime_seconds=3601,
            )

    def test_actuator_status_flow_out_of_range(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.COMPLETED,
                flow_ml=-1,
            )
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.COMPLETED,
                flow_ml=10_000_001,
            )

    def test_actuator_status_fault_code_too_long(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.FAULT,
                fault_code="x" * 51,
            )

    def test_actuator_status_fault_detail_too_long(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.FAULT,
                fault_detail="x" * 301,
            )

    def test_actuator_status_extra_field_forbidden(self):
        with pytest.raises(ValidationError):
            ActuatorStatus(
                zone_id="z1",
                state=ActuatorState.RUNNING,
                extra_field="not_allowed",
            )

    def test_actuator_status_all_states(self):
        for state in ActuatorState:
            status = ActuatorStatus(zone_id="z1", state=state)
            assert status.state == state

    def test_actuator_status_timestamp_auto_generated(self):
        status1 = ActuatorStatus(zone_id="z1", state=ActuatorState.RUNNING)
        status2 = ActuatorStatus(zone_id="z1", state=ActuatorState.RUNNING)
        assert abs((status1.timestamp - status2.timestamp).total_seconds()) < 1


class TestHubCommand:
    def test_hub_command_enum_values(self):
        assert HubCommand.START_WATER.value == "start_watering"
        assert HubCommand.STOP_WATER.value == "stop_watering"

    def test_hub_command_string_comparison(self):
        assert HubCommand.START_WATER == "start_watering"
        assert HubCommand.STOP_WATER == "stop_watering"


class TestActuatorState:
    def test_actuator_state_enum_values(self):
        assert ActuatorState.ACKNOWLEDGED.value == "ACKNOWLEDGED"
        assert ActuatorState.RUNNING.value == "RUNNING"
        assert ActuatorState.COMPLETED.value == "COMPLETED"
        assert ActuatorState.STOPPED.value == "STOPPED"
        assert ActuatorState.FAULT.value == "FAULT"

    def test_actuator_state_all_members(self):
        expected_states = {"ACKNOWLEDGED", "RUNNING", "COMPLETED", "STOPPED", "FAULT"}
        actual_states = {state.value for state in ActuatorState}
        assert actual_states == expected_states
