export const asErrorMessage = (error) => {
  if (typeof error === "string") {
    return error
  }

  if (error instanceof Error) {
    return error.message
  }

  return String(error)
}

export const normalizeSensorChannels = (channels = []) => channels.map((channel) => ({
  nodeId: typeof channel === "string" ? channel : channel.nodeId || channel.node_id,
  name: typeof channel === "string" ? "" : channel.name || "",
  cropProfileId: typeof channel === "string" ? null : channel.cropProfileId ?? channel.crop_profile_id ?? channel.effective_crop_profile_id ?? null,
  irrigationLine: typeof channel === "string" ? null : channel.irrigationLine ?? channel.irrigation_line ?? null,
  wateringConfigured: typeof channel === "string" ? false : Boolean(channel.wateringConfigured ?? channel.watering_configured),
  dryRaw: Number.isFinite(channel.dryRaw) ? channel.dryRaw : channel.moisture_raw_dry ?? null,
  wetRaw: Number.isFinite(channel.wetRaw) ? channel.wetRaw : channel.moisture_raw_wet ?? null,
})).filter((channel) => Boolean(channel.nodeId))

export const normalizePiUrl = (rawValue, defaultHost = "victory-garden.local") => {
  const trimmedValue = (rawValue || "").trim() || defaultHost
  const withScheme = /^https?:\/\//i.test(trimmedValue) ? trimmedValue : `http://${trimmedValue}`
  const url = new URL(withScheme)

  if (!url.port) {
    url.port = "3000"
  }

  return url.toString()
}

export const classifyPiConnectivityError = (error, { online = true } = {}) => {
  const message = asErrorMessage(error).toLowerCase()

  if (!online) {
    return {
      category: "local-offline",
      transient: true,
      summary: "This computer appears to be offline.",
      detail: "The installer cannot reach the Pi until your computer is back on the network.",
      recovery: "Reconnect this computer to the same network as the Pi, then retry.",
    }
  }

  if (message.includes("could not resolve")) {
    return {
      category: "dns-failure",
      transient: true,
      summary: "The Pi hostname could not be resolved on this network.",
      detail: "mDNS or DNS resolution failed before the installer could contact the Pi.",
      recovery: "Verify the hostname, or use the Pi's IP address instead.",
    }
  }

  if (
    message.includes("timed out") ||
    message.includes("operation timed out") ||
    message.includes("no route to host") ||
    message.includes("network is unreachable")
  ) {
    return {
      category: "host-unreachable",
      transient: true,
      summary: "The Pi could not be reached over the network.",
      detail: "The host did not answer before the installer's request timed out.",
      recovery: "Verify power, Wi‑Fi, and that the Pi is on the same network, then retry.",
    }
  }

  if (message.includes("connection refused") || message.includes("actively refused")) {
    return {
      category: "service-unavailable",
      transient: true,
      summary: "The Pi answered on the network, but the Victory Garden app is not accepting connections yet.",
      detail: "The web service may still be starting, restarting, or recovering from first boot.",
      recovery: "Wait briefly, then retry once the Pi app finishes starting.",
    }
  }

  if (
    message.includes("empty http response") ||
    message.includes("invalid http response") ||
    message.includes("could not read http response")
  ) {
    return {
      category: "pi-rebooting",
      transient: true,
      summary: "The Pi accepted the connection, but the web app did not finish a valid response.",
      detail: "This usually means the Pi app is restarting or the Pi is rebooting mid-request.",
      recovery: "Wait for the Pi web app to settle, then retry.",
    }
  }

  if (
    message.includes("could not connect to the pi over http") ||
    message.includes("could not send http request")
  ) {
    return {
      category: "transport-failure",
      transient: true,
      summary: "The installer could not complete an HTTP request to the Pi.",
      detail: "The TCP connection failed before the Pi could answer the request.",
      recovery: "Verify the Pi is still online, then retry.",
    }
  }

  if (message.includes("victory garden did not respond successfully")) {
    return {
      category: "unexpected-http-status",
      transient: false,
      summary: "The Pi answered, but not with a healthy Victory Garden app response.",
      detail: "The URL may point at the wrong service, or the Victory Garden app returned an unexpected HTTP status.",
      recovery: "Verify the Pi address and that the Victory Garden service is running on port 3000.",
    }
  }

  if (message.includes("could not decode json response")) {
    return {
      category: "bootstrap-json-invalid",
      transient: false,
      summary: "The Pi responded, but the installer could not decode valid setup data from it.",
      detail: "Victory Garden may be serving an unexpected build or an incomplete setup API response.",
      recovery: "Verify that the Pi is running the expected Victory Garden image and web service.",
    }
  }

  return {
    category: "unknown",
    transient: false,
    summary: "The installer could not verify the Pi.",
    detail: "The Pi request failed for an unexpected reason.",
    recovery: "Retry after verifying power, network, and the Pi address.",
  }
}

export const classifyPiDiscoveryError = (error, options = {}) => {
  const message = asErrorMessage(error)
  const lower = message.toLowerCase()

  if (lower.includes("https probing is not supported")) {
    return {
      summary: "Use an http:// Pi address, not https://.",
      detail: "This installer probes the local Pi over plain HTTP on port 3000 during setup.",
      recovery: "Replace https:// with http:// and try again.",
    }
  }

  if (lower.includes("missing host in pi url") || lower.includes("unsupported url") || lower.includes("invalid port in pi url")) {
    return {
      summary: "The Pi address is not valid.",
      detail: "Enter a hostname like victory-garden.local or a URL like http://192.168.4.33:3000.",
      recovery: "Correct the Pi address, then run Find Pi again.",
    }
  }

  if (
    lower.includes("could not resolve") ||
    lower.includes("connection refused") ||
    lower.includes("actively refused") ||
    lower.includes("timed out") ||
    lower.includes("operation timed out") ||
    lower.includes("no route to host") ||
    lower.includes("network is unreachable") ||
    lower.includes("could not connect to the pi over http") ||
    lower.includes("could not send http request") ||
    lower.includes("empty http response") ||
    lower.includes("invalid http response") ||
    lower.includes("could not read http response")
  ) {
    const classified = classifyPiConnectivityError(error, options)
    if (lower.includes("could not resolve")) {
      return {
        summary: classified.summary,
        detail: "Check the hostname you entered, confirm your computer is on the same network as the Pi, or use the Pi's IP address instead.",
        recovery: classified.recovery,
      }
    }

    return {
      summary: classified.summary,
      detail: classified.detail,
      recovery: classified.recovery,
    }
  }

  if (lower.includes("victory garden did not respond successfully")) {
    return {
      summary: "The Pi answered, but not with a healthy Victory Garden app response.",
      detail: "The Pi web service may still be starting, or the URL may point at the wrong service or path.",
      recovery: "Retry after first boot settles, or verify that the address points to the Pi's Victory Garden app.",
    }
  }

  if (lower.includes("could not decode json response")) {
    return {
      summary: "The Pi responded, but the installer could not read valid setup data from it.",
      detail: "Victory Garden may be running an unexpected build or serving an incomplete setup API response.",
      recovery: "Verify the Pi is on the expected Victory Garden build, then retry.",
    }
  }

  return {
    summary: "The installer could not verify the Pi.",
    detail: "Verify the Pi is booted, on the same network, and that Victory Garden first boot has finished.",
    recovery: "Retry after confirming power, network, and the Pi address.",
  }
}

export const retryDelayMsForAttempt = (attempt, { baseDelayMs, maxDelayMs, jitterRatio, randomFn = Math.random }) => {
  const unclamped = baseDelayMs * (2 ** Math.max(0, attempt - 1))
  const clamped = Math.min(unclamped, maxDelayMs)
  if (!jitterRatio || jitterRatio <= 0) {
    return clamped
  }

  const spread = clamped * jitterRatio
  const offset = (randomFn() * spread * 2) - spread
  return Math.max(baseDelayMs, Math.round(clamped + offset))
}

export const retryAsyncOperation = async ({
  operation,
  attempts = 8,
  baseDelayMs = 1000,
  maxDelayMs = 8000,
  jitterRatio = 0.2,
  classifyError = classifyPiConnectivityError,
  errorContext = {},
  sleepFn,
  randomFn = Math.random,
  onRetry = null,
  onFailure = null,
  onSuccess = null,
}) => {
  let lastError = null

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const result = await operation(attempt)
      if (onSuccess) {
        onSuccess({ attempt, result })
      }
      return result
    } catch (error) {
      lastError = error
      const classified = classifyError(error, errorContext)

      if (!classified.transient || attempt === attempts) {
        if (onFailure) {
          onFailure({ attempt, attempts, error, classified })
        }
        throw error
      }

      const delayMs = retryDelayMsForAttempt(attempt, { baseDelayMs, maxDelayMs, jitterRatio, randomFn })
      if (onRetry) {
        onRetry({ attempt, attempts, error, delayMs, classified })
      }
      await sleepFn(delayMs)
    }
  }

  throw lastError
}

export const buildPicoProvisioningPayload = ({ bootstrap, piVerifiedUrl, form, kind, nodeId = "" }) => {
  const zone = bootstrap?.first_zone
  if (!zone || !zone.zone_id) {
    throw new Error("The first bed has not been created yet.")
  }

  const wifiSsid = (form?.wifiSsid || "").trim()
  const wifiPassword = form?.wifiPassword ?? ""

  if (!wifiSsid) {
    throw new Error("Enter the Pico Wi‑Fi SSID in Step 2 before flashing hardware.")
  }

  if (!wifiPassword) {
    throw new Error("Enter the Pico Wi‑Fi password in Step 2 before flashing hardware.")
  }

  const connection = bootstrap?.connection_setting
  const provisioningMqttUsername = connection?.provisioning_mqtt_username || connection?.mqtt_username || "victory_garden"
  const provisioningMqttPassword = connection?.provisioning_mqtt_password

  if (!provisioningMqttPassword) {
    throw new Error("The Pi did not provide broker credentials for Pico provisioning. Find the Pi again before retrying.")
  }

  const url = new URL(piVerifiedUrl)
  return {
    kind,
    wifiSsid,
    wifiPassword,
    mqttHost: url.hostname,
    mqttPort: Number(form?.mqttPort),
    mqttUsername: provisioningMqttUsername,
    mqttPassword: provisioningMqttPassword,
    nodeId: nodeId || `${kind}-${zone.zone_id}`,
    zoneId: zone.zone_id,
    publishIntervalMs: kind === "sensor" ? zone.publish_interval_ms : null,
  }
}

export const buildActuatorProvisioningRecordRequest = ({ baseUrl, provisioningPayload = {}, provisioned = {}, board = "" }) => {
  const kind = provisioned.kind || provisioningPayload.kind
  if (kind !== "actuator") {
    return null
  }

  const logicalNodeId = String(provisioned.node_id || provisioned.nodeId || provisioningPayload.nodeId || "").trim()
  const provisioningOperationId = String(provisioned.operation_id || provisioned.operationId || "").trim()
  const zoneExternalId = String(provisioned.zone_id || provisioned.zoneId || provisioningPayload.zoneId || "").trim()
  const selectedBoard = String(board || provisioningPayload.board || "").trim()

  if (!baseUrl) {
    throw new Error("The Pi URL is required before recording actuator provisioning.")
  }

  if (!logicalNodeId) {
    throw new Error("The actuator provisioning acknowledgement did not include a node id.")
  }

  if (!provisioningOperationId) {
    throw new Error("The actuator provisioning acknowledgement did not include an operation id.")
  }

  return {
    input: {
      baseUrl,
      logicalNodeId,
      provisioningOperationId,
      zoneExternalId,
      board: selectedBoard,
    },
  }
}

export const buildActuatorRegistrationRetryRequest = ({ baseUrl, attempt = {} }) => {
  const logicalNodeId = String(attempt.logicalNodeId || attempt.logical_node_id || "").trim()
  const provisioningOperationId = String(attempt.operationId || attempt.operation_id || attempt.provisioningOperationId || attempt.provisioning_operation_id || "").trim()
  const zoneExternalId = String(attempt.zoneId || attempt.zone_id || attempt.zoneExternalId || attempt.zone_external_id || "").trim()
  const board = String(attempt.board || "").trim()

  return buildActuatorProvisioningRecordRequest({
    baseUrl,
    provisioningPayload: {
      kind: "actuator",
      nodeId: logicalNodeId,
      zoneId: zoneExternalId,
      board,
    },
    provisioned: {
      kind: "actuator",
      node_id: logicalNodeId,
      operation_id: provisioningOperationId,
      zone_id: zoneExternalId,
    },
    board,
  })
}

export const isActuatorProvisioningRecordUnsupported = (error) => {
  const message = asErrorMessage(error).toLowerCase()
  return message.includes("http 404") ||
    message.includes("cannot post /setup_api/actuator_provisioning") ||
    message.includes("no route matches")
}

const boundedText = (value, fallback = "", maxLength = 300) => {
  const text = typeof value === "string" ? value.trim() : ""
  return (text || fallback).slice(0, maxLength)
}

const normalizeOutputSummaries = (outputs) => (
  Array.isArray(outputs)
    ? outputs.map((output) => ({
      outputIndex: Number.isFinite(Number(output?.output_index ?? output?.outputIndex)) ? Number(output.output_index ?? output.outputIndex) : null,
      state: boundedText(output?.state, "unknown", 80),
    })).filter((output) => Number.isFinite(output.outputIndex))
    : []
)

const actuatorCanRetryRegistration = (attempt = {}) => (
  Boolean(String(attempt?.logicalNodeId || "").trim()) &&
  Boolean(String(attempt?.operationId || "").trim()) &&
  ["usb_acknowledged", "rails_registration_failed"].includes(String(attempt?.state || ""))
)

const actuatorRecoveryText = {
  none: {
    action: "reprovision_same",
    actionLabel: "Provision actuator",
    message: "Rails has no current actuator provisioning record.",
    recovery: "Provision the actuator Pico deliberately when the hardware is ready.",
  },
  pending_observation: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "Rails recorded provisioning and is waiting to observe the actuator.",
    recovery: "Connect the actuator to its hardware, wait for it to report, then refresh status.",
  },
  observed: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "Rails has observed the actuator but configuration is not confirmed.",
    recovery: "Refresh status after the Pi has had time to receive configuration acknowledgement.",
  },
  configured: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "Rails has configuration evidence, but actuator readiness remains incomplete.",
    recovery: "Refresh status and review output inventory or watering-target setup if Rails still reports incomplete readiness.",
  },
  stale: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "Rails has not observed the current actuator recently enough to trust it for setup.",
    recovery: "Refresh first. Reprovision this actuator or replace it only after deciding which controller should be current.",
  },
  conflict: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "Rails reports an actuator identity conflict that requires operator review.",
    recovery: "Do not choose an identity automatically. Refresh, reprovision the intended current actuator, or replace through provisioning.",
  },
  inactive: {
    action: "replace",
    actionLabel: "Provision replacement actuator",
    message: "Rails says this actuator record is inactive or superseded.",
    recovery: "Provision a replacement deliberately if this controller should be used for setup.",
  },
  unsupported: {
    action: "none",
    actionLabel: "",
    message: "This Rails setup API does not expose authoritative actuator recovery.",
    recovery: "Use local compatibility only with an older Rails server; do not treat it as durable actuator authority.",
  },
  unknown: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "Rails returned an actuator state this installer cannot interpret.",
    recovery: "Do not treat this as success. Refresh status before taking any provisioning action.",
  },
  malformed: {
    action: "refresh",
    actionLabel: "Refresh status",
    message: "The Pi returned actuator authority state that this installer could not interpret.",
    recovery: "Do not treat this as success. Refresh status before taking any provisioning action.",
  },
}

export const deriveActuatorRecovery = ({ setupActuator = null, localState = {} } = {}) => {
  const authority = setupActuator || normalizeSetupActuator(localState.bootstrap || {})
  const localAttempt = localState.actuatorProvisioningAttempt || {}
  const railsLogicalNodeId = authority.logicalNodeId || ""
  const localLogicalNodeId = localState.actuatorNodeId || localAttempt.logicalNodeId || ""
  const identityMismatch = Boolean(railsLogicalNodeId && localLogicalNodeId && railsLogicalNodeId !== localLogicalNodeId)
  const state = authority.state || "unknown"
  const safeState = authority.complete === true ? "ready" : (actuatorRecoveryText[state] ? state : "unknown")
  const base = actuatorRecoveryText[safeState] || actuatorRecoveryText.unknown
  const registrationRetry = actuatorCanRetryRegistration(localAttempt)
  const canRefresh = authority.present !== false && safeState !== "ready"
  const canRetryRegistration = safeState !== "ready" && registrationRetry
  const canReprovisionSame = ["none", "stale", "conflict", "observed", "configured"].includes(safeState) && safeState !== "ready"
  const canReplace = ["stale", "conflict", "inactive"].includes(safeState)
  const primaryAction = authority.complete === true
    ? "none"
    : (canRetryRegistration ? "retry_registration" : base.action)

  return {
    state: safeState,
    blocking: authority.complete !== true,
    action: primaryAction,
    actionLabel: primaryAction === "retry_registration" ? "Retry Rails registration" : base.actionLabel,
    message: boundedText(authority.message, base.message),
    recovery: boundedText(authority.recoveryMessage || authority.recovery, base.recovery),
    canRefresh,
    canRetryRegistration,
    canReprovisionSame,
    canReplace,
    requiresConfirmation: primaryAction === "replace" || canReplace,
    railsLogicalNodeId,
    localLogicalNodeId,
    identityMismatch,
    provisioningOperationId: authority.provisioningOperationId || localAttempt.operationId || "",
  }
}

export const normalizeSetupActuator = (bootstrap = {}) => {
  if (!hasOwn(bootstrap, "setup_actuator")) {
    return {
      present: false,
      supported: false,
      authoritative: false,
      state: "unsupported",
      persistedState: "",
      complete: false,
      malformed: false,
      message: "This Rails setup API does not expose authoritative actuator provisioning state.",
      recovery: "",
      recoveryMessage: "",
      logicalNodeId: "",
      deviceUid: "",
      provisioningOperationId: "",
      zoneExternalId: "",
      board: "",
      configStatus: "",
      provisionedAt: "",
      lastSeenAt: "",
      configAcknowledgedAt: "",
      outputs: [],
      recoveryState: null,
    }
  }

  const raw = bootstrap.setup_actuator
  const malformedResult = (message, recovery = "Refresh setup state before continuing.") => ({
    present: true,
    supported: true,
    authoritative: true,
    state: "malformed",
    persistedState: "",
    complete: false,
    malformed: true,
    message,
    recovery,
    recoveryMessage: recovery,
    logicalNodeId: "",
    deviceUid: "",
    provisioningOperationId: "",
    zoneExternalId: "",
    board: "",
    configStatus: "",
    provisionedAt: "",
    lastSeenAt: "",
    configAcknowledgedAt: "",
    outputs: [],
    recoveryState: null,
  })

  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) {
    return malformedResult(
      "The Pi returned actuator authority state that this installer could not interpret.",
      "Do not treat this as success. Refresh setup state before continuing.",
    )
  }

  const state = boundedText(raw.state, "none", 80).toLowerCase()
  const persistedState = boundedText(raw.persisted_state || raw.persistedState, "", 80).toLowerCase()
  const supported = Boolean(raw.supported ?? true)
  const authoritative = Boolean(raw.authoritative ?? true)
  const actuator = raw.actuator && typeof raw.actuator === "object" && !Array.isArray(raw.actuator) ? raw.actuator : {}
  const logicalNodeId = boundedText(actuator.logical_node_id || actuator.logicalNodeId, "", 120)
  const explicitUnsupported = !supported || !authoritative || state === "unsupported"
  const complete = !explicitUnsupported && state === "ready" && raw.complete === true
  const contradictory = raw.complete === true && state !== "ready"

  if (state === "ready" && raw.complete !== true) {
    return {
      present: true,
      supported: true,
      authoritative: true,
      state: "malformed",
      persistedState: persistedState || state,
      complete: false,
      malformed: true,
      message: boundedText(raw.message, "Rails reported actuator ready without confirmed completion."),
      recovery: boundedText(raw.recovery, "Refresh setup state before continuing. Do not use local actuator completion as success."),
      recoveryMessage: boundedText(raw.recovery_message || raw.recoveryMessage, "Refresh setup state before continuing. Do not use local actuator completion as success."),
      logicalNodeId,
      deviceUid: boundedText(actuator.device_uid || actuator.deviceUid, "", 120),
      provisioningOperationId: boundedText(actuator.provisioning_operation_id || actuator.provisioningOperationId, "", 160),
      zoneExternalId: boundedText(actuator.zone_external_id || actuator.zoneExternalId, "", 120),
      board: boundedText(actuator.board, "", 80),
      configStatus: boundedText(actuator.config_status || actuator.configStatus, "", 80),
      provisionedAt: boundedText(actuator.provisioned_at || actuator.provisionedAt, "", 80),
      lastSeenAt: boundedText(actuator.last_seen_at || actuator.lastSeenAt, "", 80),
      configAcknowledgedAt: boundedText(actuator.config_acknowledged_at || actuator.configAcknowledgedAt, "", 80),
      outputs: normalizeOutputSummaries(raw.outputs),
      recoveryState: null,
    }
  }

  const knownStates = new Set(["none", "pending_observation", "observed", "configured", "ready", "stale", "conflict", "inactive", "unsupported"])
  const effectiveState = explicitUnsupported ? "unsupported" : (knownStates.has(state) ? state : "unknown")
  const fallbackMessages = {
    none: "No Rails actuator provisioning record exists yet.",
    pending_observation: "Rails is waiting to observe the actuator after provisioning.",
    observed: "Rails has observed the actuator but has not confirmed setup readiness.",
    configured: "Rails has actuator configuration evidence, but setup readiness is not complete.",
    ready: "Rails confirmed the current actuator provisioning state.",
    stale: "The current actuator record is stale and must be refreshed before setup can continue.",
    conflict: "Rails found a conflicting actuator provisioning state.",
    inactive: "The actuator record is inactive or superseded.",
    unsupported: "This Rails setup API explicitly reports actuator authority as unsupported.",
    unknown: `Rails returned an unsupported actuator state: ${state || "blank"}.`,
  }

  const normalized = {
    present: true,
    supported,
    authoritative,
    state: contradictory ? "unknown" : effectiveState,
    persistedState: persistedState || state,
    complete,
    malformed: false,
    message: boundedText(raw.message, contradictory ? "Rails reported actuator completion for a non-ready state." : fallbackMessages[effectiveState]),
    recovery: boundedText(raw.recovery, contradictory || effectiveState === "unknown" || effectiveState === "unsupported"
      ? "Refresh setup state before continuing. Do not reprovision automatically."
      : ""),
    recoveryMessage: boundedText(raw.recovery_message || raw.recoveryMessage, contradictory || effectiveState === "unknown" || effectiveState === "unsupported"
      ? "Refresh setup state before continuing. Do not reprovision automatically."
      : ""),
    logicalNodeId,
    deviceUid: boundedText(actuator.device_uid || actuator.deviceUid, "", 120),
    provisioningOperationId: boundedText(actuator.provisioning_operation_id || actuator.provisioningOperationId, "", 160),
    zoneExternalId: boundedText(actuator.zone_external_id || actuator.zoneExternalId, "", 120),
    board: boundedText(actuator.board, "", 80),
    configStatus: boundedText(actuator.config_status || actuator.configStatus, "", 80),
    provisionedAt: boundedText(actuator.provisioned_at || actuator.provisionedAt, "", 80),
    lastSeenAt: boundedText(actuator.last_seen_at || actuator.lastSeenAt, "", 80),
    configAcknowledgedAt: boundedText(actuator.config_acknowledged_at || actuator.configAcknowledgedAt, "", 80),
    outputs: normalizeOutputSummaries(raw.outputs),
  }
  return {
    ...normalized,
    recoveryState: deriveActuatorRecovery({ setupActuator: normalized }),
  }
}

export const reconcileActuatorStateFromBootstrap = ({
  bootstrap = {},
  completed = {},
  actuatorNodeId = "",
  actuatorProvisioningAttempt = null,
} = {}) => {
  const setupActuator = normalizeSetupActuator(bootstrap)
  if (!setupActuator.present) {
    return {
      setupActuator,
      completed: { ...completed },
      actuatorNodeId,
      actuatorProvisioningAttempt,
      changed: false,
    }
  }

  const nextCompleted = { ...completed, actuator: setupActuator.complete === true }
  const nextActuatorNodeId = setupActuator.logicalNodeId || actuatorNodeId
  const railsOperationId = setupActuator.provisioningOperationId
  const nextAttempt = railsOperationId
    ? {
        ...(actuatorProvisioningAttempt || {}),
        operationId: railsOperationId,
        logicalNodeId: setupActuator.logicalNodeId || actuatorProvisioningAttempt?.logicalNodeId || "",
        state: setupActuator.state,
        complete: setupActuator.complete,
      }
    : actuatorProvisioningAttempt

  return {
    setupActuator,
    completed: nextCompleted,
    actuatorNodeId: nextActuatorNodeId,
    actuatorProvisioningAttempt: nextAttempt,
    changed: nextCompleted.actuator !== Boolean(completed.actuator) ||
      nextActuatorNodeId !== actuatorNodeId ||
      (nextAttempt?.operationId || "") !== (actuatorProvisioningAttempt?.operationId || "") ||
      (nextAttempt?.state || "") !== (actuatorProvisioningAttempt?.state || ""),
  }
}

export const effectiveActuatorDone = ({ bootstrap = {}, completed = {}, setupActuator = null } = {}) => {
  const actuatorAuthority = setupActuator || normalizeSetupActuator(bootstrap)
  if (actuatorAuthority.present) {
    return actuatorAuthority.complete === true
  }

  return Boolean(completed.actuator)
}

export const effectiveFirstZoneReady = (status = {}) => {
  if (Object.prototype.hasOwnProperty.call(status, "first_zone_ready")) {
    return Boolean(status.first_zone_ready)
  }

  return Boolean(status.zone_ready)
}

export const wateringAttemptFromStartResponse = (response = {}, { zoneId = "", nodeId = "" } = {}) => {
  const idempotencyKey = String(response.idempotency_key || response.idempotencyKey || "").trim()
  if (!idempotencyKey) {
    return null
  }

  return {
    idempotencyKey,
    zoneId: zoneId || response.zone?.id || response.zone?.zone_id || "",
    nodeId: nodeId || response.node?.node_id || "",
    status: "started",
    outcome: "pending",
  }
}

export const buildWateringStatusRequest = ({ baseUrl, zoneId, nodeId = "", attempt = {} }) => ({
  input: {
    baseUrl,
    zoneId,
    nodeId,
    idempotencyKey: attempt.idempotencyKey || "",
  },
})

const eventStatus = (status = {}) => String(status.event?.status || "").toLowerCase()
const eventKey = (status = {}) => String(status.event?.idempotency_key || status.event?.idempotencyKey || "").trim()
const responseOutcome = (status = {}) => String(status.outcome || "").toLowerCase()
const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object || {}, key)
const setupKey = (setup = {}) => String(setup.idempotency_key || setup.idempotencyKey || "").trim()

export const normalizeSetupWatering = (bootstrap = {}) => {
  if (!hasOwn(bootstrap, "setup_watering")) {
    return {
      supported: false,
      authoritative: false,
      state: "unsupported",
      outcome: "unsupported",
      complete: false,
      terminal: false,
      idempotencyKey: "",
      message: "This Rails setup API does not expose authoritative setup watering state.",
      recovery: "",
      raw: undefined,
    }
  }

  const raw = bootstrap.setup_watering
  if (raw == null) {
    return {
      supported: true,
      authoritative: true,
      state: "no_attempt",
      outcome: "none",
      complete: false,
      terminal: false,
      idempotencyKey: "",
      message: "No setup watering validation has been started.",
      recovery: "Run the first watering validation deliberately when the watering target is ready.",
      raw,
    }
  }

  if (typeof raw !== "object" || Array.isArray(raw)) {
    return {
      supported: true,
      authoritative: true,
      state: "malformed",
      outcome: "unsupported",
      complete: false,
      terminal: true,
      idempotencyKey: "",
      message: "The Pi returned setup watering state that this installer could not interpret.",
      recovery: "Do not treat this as success. Refresh setup state or retry only after inspecting the actuator state.",
      raw,
    }
  }

  const rawState = String(raw.state || "").toLowerCase()
  const outcome = String(raw.outcome || "").toLowerCase()
  const idempotencyKey = setupKey(raw)
  const message = raw.message || ""
  const recovery = raw.recovery || ""
  const terminal = Boolean(raw.terminal)

  if (["none", "no_attempt"].includes(rawState) || outcome === "none") {
    return {
      supported: true,
      authoritative: true,
      state: "no_attempt",
      outcome: "none",
      complete: false,
      terminal: false,
      idempotencyKey: "",
      message: message || "No setup watering validation has been started.",
      recovery: recovery || "Run the first watering validation deliberately when the watering target is ready.",
      raw,
    }
  }

  if (rawState === "completed" || outcome === "success") {
    if (raw.complete === true) {
      return {
        supported: true,
        authoritative: true,
        state: "completed",
        outcome: "success",
        complete: true,
        terminal: true,
        idempotencyKey,
        message: message || "Watering completed successfully.",
        recovery: "",
        raw,
      }
    }

    return {
      supported: true,
      authoritative: true,
      state: "malformed",
      outcome: "unsupported",
      complete: false,
      terminal: true,
      idempotencyKey,
      message: message || "The Pi reported completed setup watering without confirmed completion.",
      recovery: "Do not treat this as success. Refresh setup state or retry only after inspecting the actuator state.",
      raw,
    }
  }

  if (["pending", "in_progress", "running"].includes(rawState) || outcome === "in_progress") {
    return {
      supported: true,
      authoritative: true,
      state: "in_progress",
      outcome: "in_progress",
      complete: false,
      terminal: false,
      idempotencyKey,
      message: message || "Watering is still in progress.",
      recovery,
      raw,
    }
  }

  if (rawState === "target_changed" || rawState === "invalidated" || outcome === "target_changed") {
    return {
      supported: true,
      authoritative: true,
      state: "invalidated",
      outcome: "target_changed",
      complete: false,
      terminal: true,
      idempotencyKey,
      message: message || "The watering validation target changed.",
      recovery: recovery || "Review the configured watering target, then deliberately run a new validation when safe.",
      raw,
    }
  }

  if (rawState === "superseded" || outcome === "superseded") {
    return {
      supported: true,
      authoritative: true,
      state: "superseded",
      outcome: "superseded",
      complete: false,
      terminal: true,
      idempotencyKey: "",
      message: message || "This watering validation was superseded by a newer setup attempt.",
      recovery: recovery || "Refresh setup state and use only the current Rails watering attempt.",
      raw,
    }
  }

  if (
    rawState === "recovery" ||
    terminal ||
    ["stopped", "faulted", "timed_out", "unknown", "unsupported", "not_found", "missing_idempotency_key", "invalid_idempotency_key"].includes(outcome)
  ) {
    return {
      supported: true,
      authoritative: true,
      state: "recovery",
      outcome: outcome || "unsupported",
      complete: false,
      terminal: true,
      idempotencyKey,
      message: message || "The watering validation needs recovery before setup can continue.",
      recovery: recovery || "Inspect the actuator state before deliberately retrying.",
      raw,
    }
  }

  return {
    supported: true,
    authoritative: true,
    state: "malformed",
    outcome: "unsupported",
    complete: false,
    terminal: true,
    idempotencyKey,
    message: message || "The Pi returned setup watering state that this installer could not interpret.",
    recovery: recovery || "Do not treat this as success. Refresh setup state or retry only after inspecting the actuator state.",
    raw,
  }
}

export const wateringAttemptFromSetupWatering = (setupWatering = {}) => {
  if (!setupWatering.idempotencyKey) {
    return null
  }

  const target = setupWatering.raw?.target || {}
  return {
    idempotencyKey: setupWatering.idempotencyKey,
    zoneId: target.zone_id || setupWatering.raw?.event?.zone_id || "",
    nodeId: target.node_id || setupWatering.raw?.event?.node_id || "",
    status: setupWatering.state === "completed" ? "completed" : setupWatering.state === "in_progress" ? "running" : "recovery",
    outcome: setupWatering.outcome || "unknown",
    message: setupWatering.message || "",
    recovery: setupWatering.recovery || "",
  }
}

export const reconcileWateringStateFromBootstrap = ({ bootstrap = {}, completed = {}, wateringAttempt = null } = {}) => {
  const setupWatering = normalizeSetupWatering(bootstrap)
  if (!setupWatering.authoritative) {
    return {
      setupWatering,
      completed: { ...completed },
      wateringAttempt,
      changed: false,
    }
  }

  const nextCompleted = { ...completed, watering: false }
  let nextAttempt = null

  if (setupWatering.state === "completed") {
    nextCompleted.watering = true
    nextAttempt = wateringAttemptFromSetupWatering(setupWatering)
  } else if (["in_progress", "recovery", "invalidated"].includes(setupWatering.state)) {
    nextAttempt = wateringAttemptFromSetupWatering(setupWatering)
  }

  return {
    setupWatering,
    completed: nextCompleted,
    wateringAttempt: nextAttempt,
    changed: nextCompleted.watering !== Boolean(completed.watering) ||
      (nextAttempt?.idempotencyKey || "") !== (wateringAttempt?.idempotencyKey || "") ||
      (nextAttempt?.status || "") !== (wateringAttempt?.status || ""),
  }
}

export const classifyWateringStatus = (status = {}, expectedIdempotencyKey = "") => {
  const expectedKey = String(expectedIdempotencyKey || "").trim()
  const actualKey = eventKey(status)
  const outcome = responseOutcome(status)
  const currentStatus = eventStatus(status)

  if (!expectedKey) {
    return {
      state: "recovery",
      outcome: "missing_idempotency_key",
      complete: false,
      terminal: true,
      correlated: false,
      message: "The watering attempt idempotency key is missing, so setup cannot verify this cycle.",
      recovery: "Start watering again only after confirming the output is off and it is safe to deliberately retry.",
      autoRetry: false,
    }
  }

  if (!status.event) {
    return {
      state: "recovery",
      outcome: outcome || "not_found",
      complete: false,
      terminal: Boolean(status.terminal ?? true),
      correlated: false,
      message: status.message || "The current watering attempt could not be found or confirmed.",
      recovery: "Do not substitute an older watering result. Inspect the actuator state before deliberately retrying.",
      autoRetry: false,
    }
  }

  if (actualKey !== expectedKey) {
    return {
      state: "recovery",
      outcome: "mismatched_idempotency_key",
      complete: false,
      terminal: true,
      correlated: false,
      message: "The watering status response was for a different watering attempt.",
      recovery: "Do not use this result for setup. Inspect the actuator state before deliberately retrying.",
      autoRetry: false,
    }
  }

  if (currentStatus === "completed" && status.complete === true) {
    return {
      state: "success",
      outcome: "success",
      complete: true,
      terminal: true,
      correlated: true,
      message: status.message || "Watering completed successfully.",
      recovery: "",
      autoRetry: false,
    }
  }

  if (["queued", "requested", "command_sent", "published", "acknowledged", "running"].includes(currentStatus)) {
    return {
      state: "in_progress",
      outcome: "in_progress",
      complete: false,
      terminal: false,
      correlated: true,
      message: status.message || "Watering is still in progress.",
      recovery: "",
      autoRetry: false,
    }
  }

  const recoveryMessages = {
    stopped: {
      outcome: "stopped",
      message: "Watering stopped before completion was confirmed.",
      recovery: "Inspect the actuator and plant bed, then deliberately retry when safe.",
    },
    fault: {
      outcome: "faulted",
      message: "The actuator reported a watering fault.",
      recovery: "Inspect the actuator fault before retrying. The installer will not automatically issue another watering command.",
    },
    faulted: {
      outcome: "faulted",
      message: "The actuator reported a watering fault.",
      recovery: "Inspect the actuator fault before retrying. The installer will not automatically issue another watering command.",
    },
    timeout: {
      outcome: "timed_out",
      message: "The final actuator state could not be confirmed before timeout.",
      recovery: "Verify the output is off before deliberately retrying.",
    },
    timed_out: {
      outcome: "timed_out",
      message: "The final actuator state could not be confirmed before timeout.",
      recovery: "Verify the output is off before deliberately retrying.",
    },
    unknown: {
      outcome: "unknown",
      message: "The watering result could not be interpreted.",
      recovery: "Do not treat this as success. Inspect the actuator state before deliberately retrying.",
    },
  }
  const recovery = recoveryMessages[currentStatus] || {
    outcome: outcome || "unsupported",
    message: status.message || "The watering result could not be interpreted.",
    recovery: "Do not treat this as success. Inspect the actuator state before deliberately retrying.",
  }

  return {
    state: "recovery",
    outcome: recovery.outcome,
    complete: false,
    terminal: true,
    correlated: true,
    message: recovery.message,
    recovery: recovery.recovery,
    autoRetry: false,
  }
}

export const effectiveWateringDone = ({ status = {}, completed = {}, wateringAttempt = null } = {}) => {
  if (hasOwn(status, "setup_watering")) {
    const setupWatering = normalizeSetupWatering({ setup_watering: status.setup_watering })
    if (setupWatering.authoritative) {
      return setupWatering.state === "completed" && setupWatering.complete === true
    }
  }

  if (wateringAttempt && wateringAttempt.status !== "completed") {
    return false
  }

  return Boolean(status.watering_ready) || Boolean(completed.watering)
}

export const nextInstallerStep = ({ piVerifiedUrl, bootstrap, completed = {}, wateringAttempt = null }) => {
  const status = bootstrap?.status || {}
  const readingDone = Boolean(completed.reading)
  const calibrationDone = Boolean(status.calibration_ready || bootstrap?.assigned_node?.calibration_configured) || Boolean(completed.calibration)
  const wateringDone = effectiveWateringDone({
    status: hasOwn(bootstrap, "setup_watering") ? { ...status, setup_watering: bootstrap.setup_watering } : status,
    completed,
    wateringAttempt,
  })
  const sensorDone = Boolean(status.assigned_node_ready) || Boolean(completed.sensor)
  const actuatorDone = effectiveActuatorDone({ bootstrap, completed })

  if (!piVerifiedUrl) {
    return { id: "step-pi", label: "Step 1: Find The Pi" }
  }
  if (!status.connection_ready) {
    return { id: "step-connection", label: "Step 2: Configure Victory Garden" }
  }
  if (!(bootstrap?.crop_profiles || []).length) {
    return { id: "step-crop", label: "Step 3: Crop Profile Library" }
  }
  if (!effectiveFirstZoneReady(status)) {
    return { id: "step-zone", label: "Step 4: Create The First Bed" }
  }
  if (!sensorDone) {
    return { id: "step-sensor", label: "Step 5: Flash The Sensor Pico" }
  }
  if (!actuatorDone) {
    return { id: "step-actuator", label: "Step 6: Flash The Actuator Pico" }
  }
  if (!calibrationDone) {
    return { id: "step-calibration", label: "Step 7: Confirm And Calibrate The Sensors" }
  }
  if (!readingDone) {
    return { id: "step-reading", label: "Step 8: Confirm The Calibrated Reading" }
  }
  if (!wateringDone) {
    return { id: "step-watering", label: "Step 9: Confirm The First Watering" }
  }
  return { id: "step-finish", label: "Finish: Open The Dashboard" }
}
