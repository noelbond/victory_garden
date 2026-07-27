import test from "node:test"
import assert from "node:assert/strict"

import {
  buildPicoProvisioningPayload,
  nextInstallerStep,
  normalizeSetupWatering,
} from "../src/lib/installer_core.js"

const bootstrapReadyForActuatorBoundary = (overrides = {}) => ({
  status: {
    connection_ready: true,
    first_zone_ready: true,
    zone_ready: true,
    assigned_node_ready: true,
    calibration_ready: false,
    watering_ready: false,
    ...(overrides.status || {}),
  },
  crop_profiles: [{ id: 1 }],
  first_zone: {
    id: 1,
    zone_id: "zone1",
    name: "Zone 1",
    publish_interval_ms: 3600000,
  },
  assigned_node: {
    node_id: "sensor-zone1-ch0",
    calibration_configured: false,
    irrigation_line: 1,
  },
  ...overrides,
})

test("characterizes local actuator completion currently advancing beyond actuator step", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: bootstrapReadyForActuatorBoundary(),
      completed: { sensor: true, actuator: true },
    }),
    { id: "step-calibration", label: "Step 7: Confirm And Calibrate The Sensors" },
  )
})

test("characterizes local false staying at actuator step without Rails actuator authority", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: bootstrapReadyForActuatorBoundary(),
      completed: { sensor: true, actuator: false },
    }),
    { id: "step-actuator", label: "Step 6: Flash The Actuator Pico" },
  )
})

test("characterizes restored local actuator completion influencing resume step selection", () => {
  const savedSession = {
    completed: { actuator: true },
  }
  const restoredCompleted = {
    sensor: true,
    actuator: Boolean(savedSession.completed?.actuator),
    reading: false,
    calibration: false,
    watering: false,
  }

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: bootstrapReadyForActuatorBoundary(),
      completed: restoredCompleted,
    }),
    { id: "step-calibration", label: "Step 7: Confirm And Calibrate The Sensors" },
  )
})

test("characterizes bootstrap lacking actuator authority cannot clear stale local completion", () => {
  const bootstrap = bootstrapReadyForActuatorBoundary()

  assert.equal(Object.hasOwn(bootstrap, "setup_actuator"), false)
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap,
      completed: { sensor: true, actuator: true },
    }),
    { id: "step-calibration", label: "Step 7: Confirm And Calibrate The Sensors" },
  )
})

test("characterizes future Rails actuator state currently being ignored by step selection", () => {
  const bootstrap = bootstrapReadyForActuatorBoundary({
    setup_actuator: {
      authoritative: true,
      state: "conflict",
      complete: false,
      actuator: { logical_node_id: "actuator-zone-b" },
    },
  })

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap,
      completed: { sensor: true, actuator: true },
    }),
    { id: "step-calibration", label: "Step 7: Confirm And Calibrate The Sensors" },
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: bootstrapReadyForActuatorBoundary({
        setup_actuator: {
          authoritative: true,
          state: "ready",
          complete: true,
          actuator: { logical_node_id: "actuator-zone1" },
        },
      }),
      completed: { sensor: true, actuator: false },
    }),
    { id: "step-actuator", label: "Step 6: Flash The Actuator Pico" },
  )
})

test("characterizes actuator progression not requiring output inventory evidence", () => {
  const bootstrap = bootstrapReadyForActuatorBoundary({
    connection_setting: { irrigation_line_count: 4 },
    assigned_node: {
      node_id: "sensor-zone1-ch0",
      irrigation_line: 1,
      watering_configured: true,
      calibration_configured: false,
    },
  })

  assert.equal(Object.hasOwn(bootstrap, "setup_actuator"), false)
  assert.equal(Object.hasOwn(bootstrap.assigned_node, "outputs"), false)
  assert.equal(Object.hasOwn(bootstrap.assigned_node, "actuator_node_id"), false)

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap,
      completed: { sensor: true, actuator: true },
    }),
    { id: "step-calibration", label: "Step 7: Confirm And Calibrate The Sensors" },
  )
})

test("characterizes actuator provisioning payload lacking durable device and output identity", () => {
  const payload = buildPicoProvisioningPayload({
    bootstrap: {
      first_zone: {
        zone_id: "zone1",
        publish_interval_ms: 3600000,
      },
      connection_setting: {
        provisioning_mqtt_username: "installer-user",
        provisioning_mqtt_password: "secret",
      },
    },
    piVerifiedUrl: "http://192.168.4.33:3000/",
    form: {
      wifiSsid: "GardenNet",
      wifiPassword: "wifi-secret",
      mqttPort: "1883",
    },
    kind: "actuator",
  })

  assert.equal(payload.kind, "actuator")
  assert.equal(payload.nodeId, "actuator-zone1")
  assert.equal(payload.zoneId, "zone1")
  assert.equal(payload.publishIntervalMs, null)
  assert.equal(Object.hasOwn(payload, "deviceUid"), false)
  assert.equal(Object.hasOwn(payload, "firmwareVersion"), false)
  assert.equal(Object.hasOwn(payload, "outputs"), false)
  assert.equal(Object.hasOwn(payload, "irrigationLineCount"), false)
})

test("characterizes older-server bootstrap compatibility as lacking actuator authority", () => {
  const setupWatering = normalizeSetupWatering({ status: {} })

  assert.equal(setupWatering.authoritative, false)
  assert.equal(setupWatering.supported, false)
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: bootstrapReadyForActuatorBoundary(),
      completed: { sensor: true, actuator: false },
    }),
    { id: "step-actuator", label: "Step 6: Flash The Actuator Pico" },
  )
})
