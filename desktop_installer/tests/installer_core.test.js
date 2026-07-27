import test from "node:test"
import assert from "node:assert/strict"

import {
  buildActuatorProvisioningRecordRequest,
  buildPicoProvisioningPayload,
  buildWateringStatusRequest,
  classifyPiDiscoveryError,
  classifyWateringStatus,
  effectiveActuatorDone,
  effectiveFirstZoneReady,
  effectiveWateringDone,
  isActuatorProvisioningRecordUnsupported,
  nextInstallerStep,
  normalizeSetupActuator,
  normalizeSetupWatering,
  normalizeSensorChannels,
  normalizePiUrl,
  reconcileActuatorStateFromBootstrap,
  reconcileWateringStateFromBootstrap,
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

const readyBootstrap = (setupWatering) => ({
  status: {
    connection_ready: true,
    first_zone_ready: true,
    zone_ready: true,
    assigned_node_ready: true,
    reading_ready: true,
    calibration_ready: true,
    watering_ready: setupWatering?.complete === true,
  },
  crop_profiles: [{ id: 1 }],
  setup_watering: setupWatering,
})

const setupWatering = (overrides = {}) => ({
  state: "in_progress",
  complete: false,
  terminal: false,
  outcome: "in_progress",
  message: "Watering is still in progress.",
  idempotency_key: "rails-key",
  target: {
    zone_id: "zone1",
    node_id: "sensor-zone1-ch0",
    irrigation_line: 1,
  },
  event: {
    status: "running",
    idempotency_key: "rails-key",
  },
  ...overrides,
})

const setupActuator = (overrides = {}) => ({
  supported: true,
  authoritative: true,
  state: "pending_observation",
  persisted_state: overrides.state || "pending_observation",
  complete: false,
  message: "Rails is waiting to observe the actuator after provisioning.",
  recovery: "",
  actuator: {
    logical_node_id: "actuator-zone1",
    device_uid: "device-001",
    provisioning_operation_id: "provision-001",
    zone_external_id: "zone1",
    board: "pico_w",
    config_status: "pending",
    last_seen_at: "2026-07-27T12:00:00Z",
    config_acknowledged_at: "2026-07-27T12:01:00Z",
    id: 42,
    config_error: "present",
  },
  outputs: [
    { output_index: 1, state: "available", id: 101 },
    { output_index: 2, state: "assigned", node_id: "sensor-zone1-ch0" },
  ],
  internal_debug: "do not keep this",
  ...overrides,
})

const actuatorBootstrap = (setupActuatorPayload) => ({
  status: {
    connection_ready: true,
    first_zone_ready: true,
    zone_ready: true,
    assigned_node_ready: true,
    reading_ready: true,
    calibration_ready: true,
    watering_ready: true,
  },
  crop_profiles: [{ id: 1 }],
  assigned_node: { node_id: "sensor-zone1", calibration_configured: true },
  ...(setupActuatorPayload === undefined ? {} : { setup_actuator: setupActuatorPayload }),
})

test("normalizeSetupWatering distinguishes absent older Rails from explicit no attempt", () => {
  assert.equal(normalizeSetupWatering({ status: {} }).authoritative, false)

  const none = normalizeSetupWatering({ setup_watering: null })
  assert.equal(none.authoritative, true)
  assert.equal(none.state, "no_attempt")
  assert.equal(none.complete, false)
})

test("bootstrap pending attempt restores the Rails key and remains incomplete", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering({ state: "pending", event: { status: "queued", idempotency_key: "rails-key" } })),
    completed: { watering: true },
    wateringAttempt: { idempotencyKey: "local-key", status: "completed" },
  })

  assert.equal(result.completed.watering, false)
  assert.equal(result.wateringAttempt.idempotencyKey, "rails-key")
  assert.equal(result.wateringAttempt.status, "running")
})

test("bootstrap running attempt resumes polling with Rails key", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering()),
    completed: { watering: false },
    wateringAttempt: null,
  })

  assert.equal(result.setupWatering.state, "in_progress")
  assert.equal(result.wateringAttempt.idempotencyKey, "rails-key")
})

test("bootstrap completed restores completion after restart", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering({
      state: "completed",
      complete: true,
      terminal: true,
      outcome: "success",
      message: "Watering completed successfully.",
      event: { status: "completed", idempotency_key: "rails-key" },
    })),
    completed: { watering: false },
    wateringAttempt: { idempotencyKey: "local-key", status: "running" },
  })

  assert.equal(result.completed.watering, true)
  assert.equal(result.wateringAttempt.idempotencyKey, "rails-key")
  assert.equal(result.wateringAttempt.status, "completed")
})

test("bootstrap recovery clears local completion and exposes recovery", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering({
      state: "recovery",
      terminal: true,
      outcome: "faulted",
      message: "The actuator reported a watering fault.",
    })),
    completed: { watering: true },
    wateringAttempt: { idempotencyKey: "local-key", status: "completed" },
  })

  assert.equal(result.completed.watering, false)
  assert.equal(result.setupWatering.state, "recovery")
  assert.equal(result.setupWatering.message, "The actuator reported a watering fault.")
  assert.equal(result.wateringAttempt.idempotencyKey, "rails-key")
  assert.equal(result.wateringAttempt.status, "recovery")
})

test("bootstrap invalidated clears completion and exposes target-change message", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering({
      state: "target_changed",
      terminal: true,
      outcome: "target_changed",
      message: "The watering validation target changed.",
    })),
    completed: { watering: true },
  })

  assert.equal(result.completed.watering, false)
  assert.equal(result.setupWatering.state, "invalidated")
  assert.match(result.setupWatering.recovery, /target|validation/i)
})

test("bootstrap superseded does not resume the superseded key", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering({
      state: "superseded",
      terminal: true,
      outcome: "superseded",
      idempotency_key: "old-key",
    })),
    completed: { watering: true },
    wateringAttempt: { idempotencyKey: "old-key", status: "running" },
  })

  assert.equal(result.completed.watering, false)
  assert.equal(result.wateringAttempt, null)
})

test("local and Rails watering conflicts resolve in favor of Rails", () => {
  const cases = [
    {
      name: "local completed plus Rails pending",
      localCompleted: true,
      localAttempt: { idempotencyKey: "local-key", status: "completed" },
      rails: setupWatering({ state: "pending" }),
      expectedCompleted: false,
      expectedKey: "rails-key",
    },
    {
      name: "local pending plus Rails completed",
      localCompleted: false,
      localAttempt: { idempotencyKey: "local-key", status: "running" },
      rails: setupWatering({ state: "completed", complete: true, terminal: true, outcome: "success", event: { status: "completed", idempotency_key: "rails-key" } }),
      expectedCompleted: true,
      expectedKey: "rails-key",
    },
    {
      name: "local recovery plus Rails pending",
      localCompleted: false,
      localAttempt: { idempotencyKey: "local-key", status: "recovery" },
      rails: setupWatering({ state: "in_progress" }),
      expectedCompleted: false,
      expectedKey: "rails-key",
    },
  ]

  for (const item of cases) {
    const result = reconcileWateringStateFromBootstrap({
      bootstrap: readyBootstrap(item.rails),
      completed: { watering: item.localCompleted },
      wateringAttempt: item.localAttempt,
    })

    assert.equal(result.completed.watering, item.expectedCompleted, item.name)
    assert.equal(result.wateringAttempt.idempotencyKey, item.expectedKey, item.name)
  }
})

test("polling request uses only the Rails-authoritative key after reconciliation", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(setupWatering({ idempotency_key: "rails-key-b" })),
    completed: { watering: false },
    wateringAttempt: { idempotencyKey: "local-key-a", status: "running" },
  })

  assert.deepEqual(
    buildWateringStatusRequest({
      baseUrl: "http://victory-garden.local:3000/",
      zoneId: 7,
      nodeId: "sensor-zone1-ch0",
      attempt: result.wateringAttempt,
    }),
    {
      input: {
        baseUrl: "http://victory-garden.local:3000/",
        zoneId: 7,
        nodeId: "sensor-zone1-ch0",
        idempotencyKey: "rails-key-b",
      },
    },
  )
})

test("local pending plus Rails no attempt clears stale local state", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap(null),
    completed: { watering: true },
    wateringAttempt: { idempotencyKey: "local-key", status: "running" },
  })

  assert.equal(result.completed.watering, false)
  assert.equal(result.wateringAttempt, null)
})

test("malformed setup watering never yields success", () => {
  const result = reconcileWateringStateFromBootstrap({
    bootstrap: readyBootstrap("completed"),
    completed: { watering: true },
    wateringAttempt: { idempotencyKey: "local-key", status: "completed" },
  })

  assert.equal(result.setupWatering.state, "malformed")
  assert.equal(result.completed.watering, false)
  assert.equal(result.wateringAttempt, null)
})

test("step selection cannot be advanced by stale local watering when Rails is authoritative", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: readyBootstrap(setupWatering({ state: "running" })),
      completed: { sensor: true, actuator: true, reading: true, calibration: true, watering: true },
      wateringAttempt: { idempotencyKey: "local-key", status: "completed" },
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

test("actuator provisioning record request uses serial ack operation id and node identity", () => {
  const request = buildActuatorProvisioningRecordRequest({
    baseUrl: "http://victory-garden.local:3000/",
    provisioningPayload: {
      kind: "actuator",
      nodeId: "actuator-zone1",
      zoneId: "zone1",
    },
    provisioned: {
      kind: "actuator",
      operation_id: "provision-001",
      node_id: "actuator-zone1",
      zone_id: "zone1",
    },
    board: "pico_w",
  })

  assert.deepEqual(request, {
    input: {
      baseUrl: "http://victory-garden.local:3000/",
      logicalNodeId: "actuator-zone1",
      provisioningOperationId: "provision-001",
      zoneExternalId: "zone1",
      board: "pico_w",
    },
  })
})

test("actuator provisioning record request is skipped for sensor provisioning", () => {
  assert.equal(buildActuatorProvisioningRecordRequest({
    baseUrl: "http://victory-garden.local:3000/",
    provisioningPayload: { kind: "sensor", nodeId: "sensor-zone1", zoneId: "zone1" },
    provisioned: { kind: "sensor", operation_id: "provision-001", node_id: "sensor-zone1" },
    board: "pico_w",
  }), null)
})

test("actuator provisioning record request requires the returned operation id", () => {
  assert.throws(() => buildActuatorProvisioningRecordRequest({
    baseUrl: "http://victory-garden.local:3000/",
    provisioningPayload: { kind: "actuator", nodeId: "actuator-zone1", zoneId: "zone1" },
    provisioned: { kind: "actuator", node_id: "actuator-zone1" },
    board: "pico_w",
  }), /operation id/)
})

test("setup actuator normalization strips internal fields and exposes installer authority shape", () => {
  const result = normalizeSetupActuator({ setup_actuator: setupActuator({ state: "ready", complete: true }) })

  assert.equal(result.present, true)
  assert.equal(result.supported, true)
  assert.equal(result.authoritative, true)
  assert.equal(result.state, "ready")
  assert.equal(result.persistedState, "ready")
  assert.equal(result.complete, true)
  assert.equal(result.logicalNodeId, "actuator-zone1")
  assert.equal(result.deviceUid, "device-001")
  assert.equal(result.provisioningOperationId, "provision-001")
  assert.equal(result.zoneExternalId, "zone1")
  assert.equal(result.board, "pico_w")
  assert.equal(result.configStatus, "pending")
  assert.equal(result.lastSeenAt, "2026-07-27T12:00:00Z")
  assert.equal(result.configAcknowledgedAt, "2026-07-27T12:01:00Z")
  assert.deepEqual(result.outputs, [
    { outputIndex: 1, state: "available" },
    { outputIndex: 2, state: "assigned" },
  ])
  assert.equal(Object.hasOwn(result, "raw"), false)
  assert.equal(Object.hasOwn(result, "internal_debug"), false)
  assert.equal(Object.hasOwn(result, "id"), false)
})

test("actuator authority distinguishes absent older Rails from explicit none", () => {
  const absent = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(undefined),
    completed: { actuator: true },
    actuatorNodeId: "actuator-zone-local",
  })
  assert.equal(absent.setupActuator.present, false)
  assert.equal(absent.completed.actuator, true)
  assert.equal(absent.actuatorNodeId, "actuator-zone-local")
  assert.equal(effectiveActuatorDone({ bootstrap: actuatorBootstrap(undefined), completed: { actuator: true } }), true)

  const none = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "none", complete: false, actuator: null, outputs: [] })),
    completed: { actuator: true },
    actuatorNodeId: "actuator-zone-local",
  })
  assert.equal(none.setupActuator.present, true)
  assert.equal(none.completed.actuator, false)
  assert.equal(none.actuatorNodeId, "actuator-zone-local")
  assert.equal(effectiveActuatorDone({ bootstrap: actuatorBootstrap(setupActuator({ state: "none", complete: false, actuator: null })) , completed: { actuator: true } }), false)
})

test("Rails ready and complete is the only actuator authority success", () => {
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: actuatorBootstrap(setupActuator({ state: "ready", complete: true })),
      completed: { sensor: true, actuator: false, reading: true, calibration: true, watering: true },
    }),
    { id: "step-finish", label: "Finish: Open The Dashboard" },
  )

  const readyIncomplete = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "ready", complete: false })),
    completed: { actuator: true },
  })
  assert.equal(readyIncomplete.setupActuator.state, "malformed")
  assert.equal(readyIncomplete.completed.actuator, false)

  const nonReadyComplete = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "configured", complete: true })),
    completed: { actuator: true },
  })
  assert.equal(nonReadyComplete.setupActuator.state, "unknown")
  assert.equal(nonReadyComplete.completed.actuator, false)
})

test("Rails non-ready actuator states rewind stale local actuator completion", () => {
  for (const state of ["pending_observation", "observed", "configured", "stale", "conflict", "inactive"]) {
    const bootstrap = actuatorBootstrap(setupActuator({ state, complete: false }))
    const result = reconcileActuatorStateFromBootstrap({
      bootstrap,
      completed: { actuator: true, sensor: true, reading: true, calibration: true, watering: true },
      actuatorNodeId: "actuator-zone-local",
    })

    assert.equal(result.completed.actuator, false, state)
    assert.equal(result.actuatorNodeId, "actuator-zone1", state)
    assert.deepEqual(
      nextInstallerStep({
        piVerifiedUrl: "http://victory-garden.local:3000/",
        bootstrap,
        completed: { sensor: true, actuator: true, reading: true, calibration: true, watering: true },
      }),
      { id: "step-actuator", label: "Step 6: Flash The Actuator Pico" },
      state,
    )
  }
})

test("unsupported unknown and malformed actuator authority never fall back to local success", () => {
  const cases = [
    setupActuator({ supported: false, state: "unsupported", complete: false }),
    setupActuator({ authoritative: false, state: "ready", complete: true }),
    setupActuator({ state: "future_ready", complete: false }),
    "not an object",
    null,
  ]

  for (const payload of cases) {
    const result = reconcileActuatorStateFromBootstrap({
      bootstrap: actuatorBootstrap(payload),
      completed: { actuator: true },
    })

    assert.equal(result.setupActuator.present, true)
    assert.equal(result.completed.actuator, false)
    assert.equal(result.setupActuator.complete, false)
  }
})

test("actuator reconciliation adopts Rails identity and preserves matching local operation metadata", () => {
  const result = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({
      state: "pending_observation",
      complete: false,
      actuator: {
        logical_node_id: "actuator-zone-b",
        provisioning_operation_id: "provision-001",
        zone_external_id: "zone-b",
      },
    })),
    completed: { actuator: true },
    actuatorNodeId: "actuator-zone-a",
    actuatorProvisioningAttempt: {
      operationId: "provision-001",
      logicalNodeId: "actuator-zone-a",
      board: "pico_w",
      state: "usb_acknowledged",
    },
  })

  assert.equal(result.actuatorNodeId, "actuator-zone-b")
  assert.equal(result.completed.actuator, false)
  assert.equal(result.actuatorProvisioningAttempt.operationId, "provision-001")
  assert.equal(result.actuatorProvisioningAttempt.board, "pico_w")
  assert.equal(result.actuatorProvisioningAttempt.logicalNodeId, "actuator-zone-b")
  assert.equal(result.actuatorProvisioningAttempt.state, "pending_observation")
})

test("actuator bootstrap ready restores completion while non-ready rewinds without erasing unrelated input", () => {
  const restoredCompleted = {
    sensor: true,
    actuator: false,
    reading: true,
    calibration: true,
    watering: true,
  }

  const ready = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "ready", complete: true })),
    completed: restoredCompleted,
    actuatorNodeId: "",
  })
  assert.equal(ready.completed.actuator, true)
  assert.equal(ready.actuatorNodeId, "actuator-zone1")
  assert.equal(ready.completed.reading, true)

  const pending = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "pending_observation", complete: false })),
    completed: { ...restoredCompleted, actuator: true },
    actuatorNodeId: "actuator-zone1",
  })
  assert.equal(pending.completed.actuator, false)
  assert.equal(pending.completed.reading, true)
  assert.deepEqual(
    nextInstallerStep({
      piVerifiedUrl: "http://victory-garden.local:3000/",
      bootstrap: actuatorBootstrap(setupActuator({ state: "pending_observation", complete: false })),
      completed: { ...restoredCompleted, actuator: true },
    }),
    { id: "step-actuator", label: "Step 6: Flash The Actuator Pico" },
  )
})

test("actuator reconciliation is pure and does not describe automatic provisioning or retries", () => {
  const result = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "stale", complete: false, recovery: "refresh_required" })),
    completed: { actuator: true },
  })

  assert.equal(result.completed.actuator, false)
  assert.equal(result.setupActuator.recovery, "refresh_required")
  assert.equal(Object.hasOwn(result, "provision"), false)
  assert.equal(Object.hasOwn(result, "retry"), false)
  assert.equal(Object.hasOwn(result, "mutation"), false)
})

test("provisioning mutation pending response does not create durable local actuator completion", () => {
  const result = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({
      state: "pending_observation",
      complete: false,
      actuator: {
        logical_node_id: "actuator-zone1",
        provisioning_operation_id: "provision-002",
      },
    })),
    completed: { actuator: false },
    actuatorProvisioningAttempt: {
      operationId: "provision-002",
      logicalNodeId: "actuator-zone1",
      state: "usb_acknowledged",
      complete: false,
    },
  })

  assert.equal(result.completed.actuator, false)
  assert.equal(result.actuatorProvisioningAttempt.operationId, "provision-002")
  assert.equal(result.actuatorProvisioningAttempt.complete, false)
})

test("post-provisioning ready refresh advances only after Rails says ready", () => {
  const pending = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "pending_observation", complete: false })),
    completed: { actuator: false },
  })
  assert.equal(pending.completed.actuator, false)

  const ready = reconcileActuatorStateFromBootstrap({
    bootstrap: actuatorBootstrap(setupActuator({ state: "ready", complete: true })),
    completed: pending.completed,
    actuatorProvisioningAttempt: pending.actuatorProvisioningAttempt,
  })
  assert.equal(ready.completed.actuator, true)
})

test("older Rails actuator provisioning authority endpoint is explicitly detected", () => {
  assert.equal(isActuatorProvisioningRecordUnsupported(new Error("HTTP 404 from /setup_api/actuator_provisioning")), true)
  assert.equal(isActuatorProvisioningRecordUnsupported(new Error("Validation failed")), false)
})

test("classifyPiDiscoveryError distinguishes service startup failures", () => {
  const result = classifyPiDiscoveryError(new Error("could not connect to the Pi over HTTP: 192.168.4.33:3000: Connection refused"))
  assert.equal(result.summary, "The Pi answered on the network, but the Victory Garden app is not accepting connections yet.")
  assert.match(result.recovery, /Wait briefly/)
})
