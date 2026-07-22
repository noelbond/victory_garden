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

export const buildPicoProvisioningPayload = ({ bootstrap, piVerifiedUrl, form, kind }) => {
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
    nodeId: `${kind}-${zone.zone_id}`,
    zoneId: zone.zone_id,
    publishIntervalMs: kind === "sensor" ? zone.publish_interval_ms : null,
  }
}

export const nextInstallerStep = ({ piVerifiedUrl, bootstrap, completed = {} }) => {
  const status = bootstrap?.status || {}
  const readingDone = Boolean(completed.reading)
  const calibrationDone = Boolean(status.calibration_ready || bootstrap?.assigned_node?.calibration_configured) || Boolean(completed.calibration)
  const wateringDone = Boolean(status.watering_ready) || Boolean(completed.watering)
  const sensorDone = Boolean(status.assigned_node_ready) || Boolean(completed.sensor)
  const actuatorDone = Boolean(completed.actuator)

  if (!piVerifiedUrl) {
    return { id: "step-pi", label: "Step 1: Find The Pi" }
  }
  if (!status.connection_ready) {
    return { id: "step-connection", label: "Step 2: Configure Victory Garden" }
  }
  if (!(bootstrap?.crop_profiles || []).length) {
    return { id: "step-crop", label: "Step 3: Crop Profile Library" }
  }
  if (!status.zone_ready) {
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
