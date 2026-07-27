import test from "node:test"
import assert from "node:assert/strict"

import {
  buildPicoProvisioningPayload,
  buildWateringStatusRequest,
  classifyPiDiscoveryError,
  classifyWateringStatus,
  effectiveFirstZoneReady,
  effectiveWateringDone,
  nextInstallerStep,
  normalizeSensorChannels,
  normalizePiUrl,
  wateringAttemptFromStartResponse,
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
      completed: { actuator: true, calibration: true },
    }),
    { id: "step-reading", label: "Step 8: Confirm The Calibrated Reading" },
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: { connection_ready: true, zone_ready: true, assigned_node_ready: true },
        crop_profiles: [{ id: 1 }],
      },
      completed: { actuator: true, reading: true, calibration: true, watering: true },
    }),
    { id: "step-finish", label: "Finish: Open The Dashboard" },
  )
})


test("effectiveFirstZoneReady uses explicit false before legacy fallback", () => {
  assert.equal(effectiveFirstZoneReady({
    first_zone_ready: true,
    watering_targets_ready: false,
    zone_ready: false,
  }), true)

  assert.equal(effectiveFirstZoneReady({
    first_zone_ready: false,
    watering_targets_ready: true,
    zone_ready: true,
  }), false)

  assert.equal(effectiveFirstZoneReady({ zone_ready: true }), true)
  assert.equal(effectiveFirstZoneReady({ zone_ready: false }), false)
})

test("watering start response retains the attempt idempotency key", () => {
  assert.deepEqual(
    wateringAttemptFromStartResponse(
      {
        idempotency_key: "attempt-123",
        zone: { id: 7, zone_id: "zone1" },
        node: { node_id: "sensor-zone1-ch0" },
      },
      { zoneId: 7, nodeId: "sensor-zone1-ch0" },
    ),
    {
      idempotencyKey: "attempt-123",
      zoneId: 7,
      nodeId: "sensor-zone1-ch0",
      status: "started",
      outcome: "pending",
    },
  )

  assert.equal(wateringAttemptFromStartResponse({ queued: true }), null)
})

test("watering status request carries the attempt idempotency key", () => {
  assert.deepEqual(
    buildWateringStatusRequest({
      baseUrl: "http://victory-garden.local:3000/",
      zoneId: 12,
      nodeId: "sensor-zone1-ch0",
      attempt: { idempotencyKey: "attempt-123" },
    }),
    {
      input: {
        baseUrl: "http://victory-garden.local:3000/",
        zoneId: 12,
        nodeId: "sensor-zone1-ch0",
        idempotencyKey: "attempt-123",
      },
    },
  )
})

test("correlated completed watering status is the only setup success", () => {
  const result = classifyWateringStatus({
    complete: true,
    terminal: true,
    outcome: "success",
    event: {
      status: "completed",
      idempotency_key: "attempt-123",
    },
  }, "attempt-123")

  assert.equal(result.state, "success")
  assert.equal(result.complete, true)
  assert.equal(result.correlated, true)
})

test("watering status in-progress outcomes do not advance setup", () => {
  for (const status of ["running", "acknowledged"]) {
    const result = classifyWateringStatus({
      complete: false,
      terminal: false,
      event: {
        status,
        idempotency_key: "attempt-123",
      },
    }, "attempt-123")

    assert.equal(result.state, "in_progress")
    assert.equal(result.complete, false)
    assert.equal(result.terminal, false)
  }
})

test("watering status recovery outcomes do not advance and never auto retry", () => {
  for (const status of ["stopped", "fault", "timeout", "unknown"]) {
    const result = classifyWateringStatus({
      complete: false,
      terminal: true,
      event: {
        status,
        idempotency_key: "attempt-123",
      },
    }, "attempt-123")

    assert.equal(result.state, "recovery", status)
    assert.equal(result.complete, false, status)
    assert.equal(result.terminal, true, status)
    assert.equal(result.autoRetry, false, status)
    assert.match(result.recovery, /retry|success|Inspect|Verify|Do not treat/)
  }
})

test("missing event and mismatched idempotency key do not advance setup", () => {
  const missing = classifyWateringStatus({
    complete: false,
    terminal: true,
    outcome: "not_found",
    event: null,
  }, "attempt-123")
  assert.equal(missing.state, "recovery")
  assert.equal(missing.correlated, false)

  const mismatched = classifyWateringStatus({
    complete: true,
    terminal: true,
    event: {
      status: "completed",
      idempotency_key: "historical-attempt",
    },
  }, "attempt-123")
  assert.equal(mismatched.state, "recovery")
  assert.equal(mismatched.outcome, "mismatched_idempotency_key")
  assert.equal(mismatched.complete, false)
})

test("historical local watering completion does not satisfy current in-progress attempt", () => {
  assert.equal(
    effectiveWateringDone({
      status: { watering_ready: false },
      completed: { watering: true },
      wateringAttempt: {
        idempotencyKey: "attempt-123",
        status: "running",
      },
    }),
    false,
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: {
          connection_ready: true,
          zone_ready: true,
          assigned_node_ready: true,
          reading_ready: true,
          calibration_ready: true,
          watering_ready: false,
        },
        crop_profiles: [{ id: 1 }],
      },
      completed: { sensor: true, actuator: true, reading: true, calibration: true, watering: true },
      wateringAttempt: {
        idempotencyKey: "attempt-123",
        status: "running",
      },
    }),
    { id: "step-watering", label: "Step 9: Confirm The First Watering" },
  )
})

test("nextInstallerStep gates hardware setup on first_zone_ready when present", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: {
          connection_ready: true,
          first_zone_ready: true,
          watering_targets_ready: false,
          zone_ready: false,
          assigned_node_ready: true,
          reading_ready: true,
          calibration_ready: true,
          watering_ready: true,
        },
        crop_profiles: [{ id: 1 }],
        first_zone: { id: 1, name: "Front Planter", crop_profile_id: 1 },
      },
      completed: { sensor: true, actuator: true, reading: true, calibration: true, watering: true },
    }),
    { id: "step-finish", label: "Finish: Open The Dashboard" },
  )
})

test("nextInstallerStep keeps explicit false first_zone_ready authoritative", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: {
          connection_ready: true,
          first_zone_ready: false,
          watering_targets_ready: true,
          zone_ready: true,
          assigned_node_ready: true,
          reading_ready: true,
          calibration_ready: true,
          watering_ready: true,
        },
        crop_profiles: [{ id: 1 }],
      },
      completed: { sensor: true, actuator: true, reading: true, calibration: true, watering: true },
    }),
    { id: "step-zone", label: "Step 4: Create The First Bed" },
  )
})

test("nextInstallerStep falls back to legacy zone_ready only when first_zone_ready is absent", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: {
          connection_ready: true,
          zone_ready: true,
          assigned_node_ready: false,
        },
        crop_profiles: [{ id: 1 }],
      },
      completed: {},
    }),
    { id: "step-sensor", label: "Step 5: Flash The Sensor Pico" },
  )

  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: {
          connection_ready: true,
          zone_ready: false,
          assigned_node_ready: true,
        },
        crop_profiles: [{ id: 1 }],
      },
      completed: { sensor: true, actuator: true, reading: true, calibration: true, watering: true },
    }),
    { id: "step-zone", label: "Step 4: Create The First Bed" },
  )
})

test("nextInstallerStep characterizes local completion winning over bootstrap gaps", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: {
        status: {
          connection_ready: true,
          zone_ready: true,
          assigned_node_ready: true,
          reading_ready: false,
          calibration_ready: false,
          watering_ready: false,
        },
        crop_profiles: [{ id: 1 }],
        assigned_node: { node_id: "sensor-zone1", calibration_configured: false },
      },
      completed: { actuator: true, reading: true, calibration: true, watering: true },
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
  })
})

test("classifyPiDiscoveryError distinguishes service startup failures", () => {
  const result = classifyPiDiscoveryError(new Error("could not connect to the Pi over HTTP: 192.168.4.33:3000: Connection refused"))
  assert.equal(result.summary, "The Pi answered on the network, but the Victory Garden app is not accepting connections yet.")
  assert.match(result.recovery, /Wait briefly/)
})
