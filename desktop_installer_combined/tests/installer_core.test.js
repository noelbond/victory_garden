import test from "node:test"
import assert from "node:assert/strict"

import {
  buildPicoProvisioningPayload,
  classifyPiDiscoveryError,
  localUtcOffsetHours,
  nextInstallerStep,
  normalizeSensorChannels,
  normalizePiUrl,
} from "../src/lib/installer_core.js"

test("normalizeSensorChannels preserves explicit provisioning and backend channel ids", () => {
  assert.deepEqual(normalizeSensorChannels([
    "sensor-zone1-ch0",
    { node_id: "sensor-zone1-ch1", moisture_raw_dry: 100, moisture_raw_wet: 200 },
  ]), [
    { nodeId: "sensor-zone1-ch0", name: "", cropProfileId: null, irrigationLine: null, wateringConfigured: false, dryRaw: null, wetRaw: null },
    { nodeId: "sensor-zone1-ch1", name: "", cropProfileId: null, irrigationLine: null, wateringConfigured: false, dryRaw: 100, wetRaw: 200 },
  ])
})

test("normalizePiUrl adds scheme and default port", () => {
  assert.equal(normalizePiUrl("victory-garden.local"), "http://victory-garden.local:3000/")
  assert.equal(normalizePiUrl("http://192.168.4.33"), "http://192.168.4.33:3000/")
  assert.equal(normalizePiUrl("http://192.168.4.33:4000"), "http://192.168.4.33:4000/")
})

test("nextInstallerStep walks the unified installer flow in order", () => {
  assert.deepEqual(
    nextInstallerStep({ piVerifiedUrl: "", bootstrap: null, completed: {} }),
    { id: "step-pi", label: "Step 1: Find The Pi" },
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: { status: {} },
      completed: {},
    }),
    { id: "step-connection", label: "Step 2: Configure Victory Garden" },
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: { connection_ready: true, zone_ready: true, assigned_node_ready: true },
        crop_profiles: [{ id: 1 }],
      },
      completed: { calibration: true },
    }),
    { id: "step-reading", label: "Step 7: Confirm The Calibrated Reading" },
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: { connection_ready: true, zone_ready: true, assigned_node_ready: true },
        crop_profiles: [{ id: 1 }],
      },
      completed: { reading: true, calibration: true, watering: true },
    }),
    { id: "step-finish", label: "Finish: Open The Dashboard" },
  )
})

test("nextInstallerStep treats skipped reading/watering the same as done", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: { connection_ready: true, zone_ready: true, assigned_node_ready: true },
        crop_profiles: [{ id: 1 }],
      },
      completed: { calibration: true, readingSkipped: true, wateringSkipped: true },
    }),
    { id: "step-finish", label: "Finish: Open The Dashboard" },
  )
})

test("buildPicoProvisioningPayload uses Pi-managed broker credentials", () => {
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
    kind: "sensor",
  })

  assert.deepEqual(payload, {
    kind: "sensor",
    wifiSsid: "GardenNet",
    wifiPassword: "wifi-secret",
    mqttHost: "192.168.4.33",
    mqttPort: 1883,
    mqttUsername: "installer-user",
    mqttPassword: "secret",
    nodeId: "sensor-zone1",
    zoneId: "zone1",
    publishIntervalMs: 3600000,
    utcOffsetHours: localUtcOffsetHours(),
  })
})

test("localUtcOffsetHours converts getTimezoneOffset minutes to whole hours, clamped to firmware range", () => {
  // getTimezoneOffset() is minutes *behind* UTC (positive for west-of-UTC
  // zones), so it's sign-inverted relative to utc_offset_hours.
  assert.equal(localUtcOffsetHours(() => ({ getTimezoneOffset: () => 300 })), -5) // US Eastern (UTC-5)
  assert.equal(localUtcOffsetHours(() => ({ getTimezoneOffset: () => -330 })), 6) // rounds from 5.5 (India, UTC+5:30)
  assert.equal(localUtcOffsetHours(() => ({ getTimezoneOffset: () => 0 })), 0) // UTC
  assert.equal(localUtcOffsetHours(() => ({ getTimezoneOffset: () => -900 })), 14) // clamped at firmware max
  assert.equal(localUtcOffsetHours(() => ({ getTimezoneOffset: () => 900 })), -12) // clamped at firmware min
})

test("buildPicoProvisioningPayload gives the combined kind a publish interval, like sensor", () => {
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
    kind: "combined",
  })

  assert.equal(payload.nodeId, "combined-zone1")
  assert.equal(payload.publishIntervalMs, 3600000)
})

test("classifyPiDiscoveryError distinguishes service startup failures", () => {
  const result = classifyPiDiscoveryError(new Error("could not connect to the Pi over HTTP: 192.168.4.33:3000: Connection refused"))
  assert.equal(result.summary, "The Pi answered on the network, but the Victory Garden app is not accepting connections yet.")
  assert.match(result.recovery, /Wait briefly/)
})
