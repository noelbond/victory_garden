import "./styles.css"
import { invoke } from "@tauri-apps/api/core"
import {
  asErrorMessage,
  buildWateringStatusRequest,
  buildPicoProvisioningPayload,
  classifyPiConnectivityError,
  classifyPiDiscoveryError,
  classifyWateringStatus,
  effectiveFirstZoneReady,
  effectiveWateringDone,
  nextInstallerStep,
  normalizeSensorChannels,
  normalizePiUrl,
  retryAsyncOperation,
  wateringAttemptFromStartResponse,
} from "./lib/installer_core.js"

// The Rust backend's EXPECTED_SENSOR_CHANNEL_COUNT is the single source of
// truth (comment there notes it must match firmware VG_ADS1115_CHANNEL_COUNT);
// fetched once and cached rather than duplicating the literal here.
let cachedExpectedSensorChannelCount = null
const expectedSensorChannelCount = async () => {
  if (cachedExpectedSensorChannelCount === null) {
    cachedExpectedSensorChannelCount = await invoke("expected_sensor_channel_count")
  }
  return cachedExpectedSensorChannelCount
}

const firmwareNames = {
  sensor: {
    pico_w: "pico_w_sensor_node.uf2",
    pico2_w: "pico2_w_sensor_node.uf2",
  },
  actuator: {
    pico_w: "pico_w_actuator_node.uf2",
    pico2_w: "pico2_w_actuator_node.uf2",
  },
}

const SESSION_STORAGE_KEY = "vg-installer:session"

const state = {
  piChecking: false,
  piVerifiedUrl: "",
  bootstrap: null,
  devices: [],
  refreshInFlight: false,
  flashing: {
    sensor: false,
    actuator: false,
    reading: false,
    calibration: false,
    watering: false,
  },
  completed: {
    sensor: false,
    actuator: false,
    reading: false,
    calibration: false,
    watering: false,
  },
  provisioned: {
    sensor: false,
    actuator: false,
  },
  messages: {
    sensor: "",
    actuator: "",
  },
  wateringAttempt: null,
  channels: [],
  selectedCropProfileId: null,
  sensorDeviceId: "",
  actuatorNodeId: "",
}

const normalizeChannels = normalizeSensorChannels

const channelNodeIds = () => state.channels.map((channel) => channel.nodeId)
const primarySensorNodeId = () => channelNodeIds()[0] || state.bootstrap?.assigned_node?.channels?.[0]?.node_id || ""
const allChannelsHave = (key) => state.channels.length > 0 && state.channels.every((channel) => Number.isFinite(channel[key]))
const allChannelsConfigured = () => state.channels.length > 0 && state.channels.every((channel) => (
  channel.name && Number.isFinite(Number(channel.cropProfileId)) && Number.isFinite(Number(channel.irrigationLine))
))
const celsiusToFahrenheit = (value) => (value * 9 / 5) + 32
const formatTemperatureF = (value) => Number.isFinite(value) ? `${celsiusToFahrenheit(value).toFixed(1)} F` : "—"
const formatHumidity = (value) => Number.isFinite(value) ? `${value.toFixed(1)}%` : "—"

const elements = {
  wizardUrl: document.querySelector("#wizard-url"),
  findPi: document.querySelector("#find-pi"),
  wizardStatus: document.querySelector("#wizard-status"),
  mqttHost: document.querySelector("#mqtt-host"),
  mqttPort: document.querySelector("#mqtt-port"),
  mqttUsername: document.querySelector("#mqtt-username"),
  mqttPassword: document.querySelector("#mqtt-password"),
  irrigationLineCount: document.querySelector("#irrigation-line-count"),
  picoWifiSsid: document.querySelector("#pico-wifi-ssid"),
  picoWifiPassword: document.querySelector("#pico-wifi-password"),
  saveConnection: document.querySelector("#save-connection"),
  connectionStatus: document.querySelector("#connection-status"),
  cropName: document.querySelector("#crop-name"),
  dryThreshold: document.querySelector("#dry-threshold"),
  maxPulseRuntime: document.querySelector("#max-pulse-runtime"),
  dailyMaxRuntime: document.querySelector("#daily-max-runtime"),
  createCropProfile: document.querySelector("#create-crop-profile"),
  cropStatus: document.querySelector("#crop-status"),
  cropProfileSummary: document.querySelector("#crop-profile-summary"),
  zoneName: document.querySelector("#zone-name"),
  sensorChannelCount: document.querySelector("#sensor-channel-count"),
  zoneFrequencyHours: document.querySelector("#zone-frequency-hours"),
  saveZone: document.querySelector("#save-zone"),
  zoneStatus: document.querySelector("#zone-status"),
  sensorDeviceStatus: document.querySelector("#sensor-device-status"),
  actuatorDeviceStatus: document.querySelector("#actuator-device-status"),
  sensorDetectedTitle: document.querySelector("#sensor-detected-title"),
  sensorDetectedDetail: document.querySelector("#sensor-detected-detail"),
  sensorStatus: document.querySelector("#sensor-status"),
  sensorFlash: document.querySelector("#flash-sensor"),
  plantChannelSettings: document.querySelector("#plant-channel-settings"),
  savePlantSettings: document.querySelector("#save-plant-settings"),
  plantSettingsStatus: document.querySelector("#plant-settings-status"),
  actuatorDetectedTitle: document.querySelector("#actuator-detected-title"),
  actuatorDetectedDetail: document.querySelector("#actuator-detected-detail"),
  actuatorStatus: document.querySelector("#actuator-status"),
  actuatorFlash: document.querySelector("#flash-actuator"),
  requestReading: document.querySelector("#request-reading"),
  readingStatus: document.querySelector("#reading-status"),
  readingNodeSummary: document.querySelector("#reading-node-summary"),
  readingDetailSummary: document.querySelector("#reading-detail-summary"),
  captureDryCalibration: document.querySelector("#capture-dry-calibration"),
  captureWetCalibration: document.querySelector("#capture-wet-calibration"),
  calibrationStatus: document.querySelector("#calibration-status"),
  calibrationDrySummary: document.querySelector("#calibration-dry-summary"),
  calibrationWetSummary: document.querySelector("#calibration-wet-summary"),
  calibrationChannelProgress: document.querySelector("#calibration-channel-progress"),
  startWatering: document.querySelector("#start-watering"),
  wateringStatus: document.querySelector("#watering-status"),
  wateringZoneSummary: document.querySelector("#watering-zone-summary"),
  wateringDetailSummary: document.querySelector("#watering-detail-summary"),
  verifiedUrl: document.querySelector("#verified-url"),
  openDashboard: document.querySelector("#open-dashboard"),
  exportDiagnostics: document.querySelector("#export-diagnostics"),
  finishStatus: document.querySelector("#finish-status"),
  supportStatus: document.querySelector("#support-status"),
  refreshSensorDevices: document.querySelector("#refresh-sensor-devices"),
  refreshActuatorDevices: document.querySelector("#refresh-actuator-devices"),
  progressPi: document.querySelector("#progress-pi"),
  progressConnection: document.querySelector("#progress-connection"),
  progressZone: document.querySelector("#progress-zone"),
  progressSensor: document.querySelector("#progress-sensor"),
  progressActuator: document.querySelector("#progress-actuator"),
  progressReading: document.querySelector("#progress-reading"),
  progressCalibration: document.querySelector("#progress-calibration"),
  progressWatering: document.querySelector("#progress-watering"),
  piStepPill: document.querySelector("#pi-step-pill"),
  connectionStepPill: document.querySelector("#connection-step-pill"),
  cropStepPill: document.querySelector("#crop-step-pill"),
  zoneStepPill: document.querySelector("#zone-step-pill"),
  sensorStepPill: document.querySelector("#sensor-step-pill"),
  actuatorStepPill: document.querySelector("#actuator-step-pill"),
  readingStepPill: document.querySelector("#reading-step-pill"),
  calibrationStepPill: document.querySelector("#calibration-step-pill"),
  wateringStepPill: document.querySelector("#watering-step-pill"),
  finishStepPill: document.querySelector("#finish-step-pill"),
}

const sleep = (milliseconds) => new Promise((resolve) => {
  window.setTimeout(resolve, milliseconds)
})

const browserOnline = () => (typeof navigator === "undefined" ? true : navigator.onLine !== false)

const appendInstallerLog = async ({ level = "info", category, action, message, details = null }) => {
  try {
    await invoke("write_installer_log", {
      entry: {
        level,
        category,
        action,
        message,
        details,
      },
    })
  } catch {
    // Logging should never block installer progress.
  }
}

const logInstallerInfo = (category, action, message, details = null) => (
  appendInstallerLog({ level: "info", category, action, message, details })
)

const logInstallerWarn = (category, action, message, details = null) => (
  appendInstallerLog({ level: "warn", category, action, message, details })
)

const logInstallerError = (category, action, message, details = null) => (
  appendInstallerLog({ level: "error", category, action, message, details })
)

const buildStatus = ({ summary, detail = "", recovery = "", technicalDetail = "" }) => ({
  summary,
  detail,
  recovery,
  technicalDetail,
})

const withTimeout = async (promise, timeoutMs, timeoutMessage) => {
  if (!timeoutMs || timeoutMs <= 0) {
    return promise
  }

  let timerId = null
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timerId = window.setTimeout(() => {
          reject(new Error(timeoutMessage))
        }, timeoutMs)
      }),
    ])
  } finally {
    if (timerId !== null) {
      window.clearTimeout(timerId)
    }
  }
}

const renderStatus = (element, status) => {
  if (!element) {
    return
  }

  if (typeof status === "string") {
    element.textContent = status
    return
  }

  const parts = [status.summary]
  if (status.detail) {
    parts.push(status.detail)
  }
  if (status.recovery) {
    parts.push(`Next: ${status.recovery}`)
  }
  if (status.technicalDetail) {
    parts.push(`Technical detail: ${status.technicalDetail}`)
  }

  element.textContent = parts.filter(Boolean).join(" ")
}

const installerSetupState = () => ({
  piVerifiedUrl: state.piVerifiedUrl,
  session: sessionSnapshot(),
  bootstrap: state.bootstrap,
  devices: state.devices,
  selectedCropProfileId: state.selectedCropProfileId,
  sensorDeviceId: state.sensorDeviceId,
  channels: state.channels.map((channel) => ({ ...channel })),
  actuatorNodeId: state.actuatorNodeId,
  completed: { ...state.completed },
  provisioned: { ...state.provisioned },
  messages: { ...state.messages },
})

const piApiFailureStatus = (action, error, fallbackDetail, fallbackRecovery) => {
  const classified = classifyPiConnectivityError(error, { online: typeof navigator === "undefined" ? true : navigator.onLine !== false })
  if (classified.category !== "unknown") {
    return buildStatus({
      summary: `${action} could not be completed because the Pi is unavailable.`,
      detail: `${classified.summary} ${classified.detail}`.trim(),
      recovery: classified.recovery,
      technicalDetail: asErrorMessage(error),
    })
  }

  return buildStatus({
    summary: `${action} failed.`,
    detail: fallbackDetail,
    recovery: fallbackRecovery,
    technicalDetail: asErrorMessage(error),
  })
}

const piRetryDetail = (classified, attempt, attempts, delayMs) => (
  `${classified.summary} Retrying ${attempt}/${attempts} in ${(delayMs / 1000).toFixed(1)}s.`
)

const invokePiApiWithRetry = async (command, payload, options = {}) => {
  const {
    attempts = 8,
    delayMs = null,
    baseDelayMs = 1000,
    maxDelayMs = 8000,
    timeoutMs = 10000,
    jitterRatio = 0.2,
    onRetry = null,
    context = "Pi API request",
  } = options
  const effectiveBaseDelayMs = Number.isFinite(delayMs) && delayMs > 0 ? delayMs : baseDelayMs
  void logInstallerInfo("api", "request_start", `Starting ${command}.`, {
    command,
    attempts,
    timeoutMs,
    baseDelayMs: effectiveBaseDelayMs,
    maxDelayMs,
    payload,
  })

  return retryAsyncOperation({
    attempts,
    baseDelayMs: effectiveBaseDelayMs,
    maxDelayMs,
    jitterRatio,
    classifyError: (error) => classifyPiConnectivityError(error, {
      online: typeof navigator === "undefined" ? true : navigator.onLine !== false,
    }),
    errorContext: {},
    sleepFn: sleep,
    operation: async (attempt) => {
      const response = await withTimeout(
        invoke(command, payload),
        timeoutMs,
        `${context} timed out after ${timeoutMs}ms.`,
      )
      void logInstallerInfo("api", "request_success", `${command} succeeded.`, {
        command,
        attempt,
      })
      return response
    },
    onRetry: ({ attempt, attempts: totalAttempts, error, delayMs: retryDelayMs, classified }) => {
      if (onRetry) {
        onRetry({
          attempt,
          attempts: totalAttempts,
          error: asErrorMessage(error),
          delayMs: retryDelayMs,
          classified,
        })
      }

      void logInstallerWarn("api", "request_retry", `${command} will retry after a Pi connectivity failure.`, {
        command,
        attempt,
        attempts: totalAttempts,
        error: asErrorMessage(error),
        classified,
        delayMs: retryDelayMs,
      })
    },
    onFailure: ({ attempt, error, classified }) => {
      void logInstallerError("api", "request_failed", `${command} failed.`, {
        command,
        attempt,
        error: asErrorMessage(error),
        classified,
      })
    },
  })
}

const probePiWithRetry = async (url, options = {}) => {
  const {
    attempts = 6,
    delayMs = null,
    baseDelayMs = 1000,
    maxDelayMs = 8000,
    timeoutMs = 10000,
    jitterRatio = 0.2,
    onRetry = null,
  } = options
  const effectiveBaseDelayMs = Number.isFinite(delayMs) && delayMs > 0 ? delayMs : baseDelayMs

  return retryAsyncOperation({
    attempts,
    baseDelayMs: effectiveBaseDelayMs,
    maxDelayMs,
    jitterRatio,
    classifyError: (error) => classifyPiConnectivityError(error, {
      online: typeof navigator === "undefined" ? true : navigator.onLine !== false,
    }),
    errorContext: {},
    sleepFn: sleep,
    operation: async () => withTimeout(
        invoke("probe_victory_garden", { url }),
        timeoutMs,
        `Pi discovery probe timed out after ${timeoutMs}ms.`,
      ),
    onRetry: ({ attempt, attempts: totalAttempts, error, delayMs: retryDelayMs, classified }) => {
      if (onRetry) {
        onRetry({
          attempt,
          attempts: totalAttempts,
          error: asErrorMessage(error),
          delayMs: retryDelayMs,
          classified,
        })
      }
    },
  })
}

const savePreferences = () => {
  window.localStorage.setItem("vg-installer:wizard-url", elements.wizardUrl.value)
  window.localStorage.setItem("vg-installer:pico-wifi-ssid", elements.picoWifiSsid.value)
}

const hasRecoverableSessionState = () => (
  Boolean(state.piVerifiedUrl) ||
  Object.values(state.completed).some(Boolean) ||
  Object.values(state.provisioned).some(Boolean) ||
  Boolean(state.wateringAttempt?.idempotencyKey) ||
  Boolean(state.sensorDeviceId) ||
  state.channels.length > 0 ||
  Boolean(state.actuatorNodeId)
)

const sessionSnapshot = () => ({
  piVerifiedUrl: state.piVerifiedUrl,
  selectedCropProfileId: state.selectedCropProfileId,
  sensorDeviceId: state.sensorDeviceId,
  channels: state.channels.map((channel) => ({ ...channel })),
  actuatorNodeId: state.actuatorNodeId,
  completed: { ...state.completed },
  provisioned: { ...state.provisioned },
  messages: { ...state.messages },
  wateringAttempt: state.wateringAttempt ? { ...state.wateringAttempt } : null,
  savedAt: new Date().toISOString(),
})

const saveSessionState = () => {
  if (!hasRecoverableSessionState()) {
    window.localStorage.removeItem(SESSION_STORAGE_KEY)
    return
  }

  window.localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify(sessionSnapshot()))
}

const clearSessionState = () => {
  window.localStorage.removeItem(SESSION_STORAGE_KEY)
}

const loadSessionState = () => {
  const raw = window.localStorage.getItem(SESSION_STORAGE_KEY)
  if (!raw) {
    return null
  }

  try {
    return JSON.parse(raw)
  } catch {
    clearSessionState()
    return null
  }
}

const resetInstallerState = () => {
  state.piChecking = false
  state.piVerifiedUrl = ""
  state.bootstrap = null
  state.devices = []
  state.refreshInFlight = false
  state.flashing = {
    sensor: false,
    actuator: false,
    reading: false,
    calibration: false,
    watering: false,
  }
  state.completed = {
    sensor: false,
    actuator: false,
    reading: false,
    calibration: false,
    watering: false,
  }
  state.provisioned = {
    sensor: false,
    actuator: false,
  }
  state.messages = {
    sensor: "",
    actuator: "",
  }
  state.channels = []
  state.selectedCropProfileId = null
  state.sensorDeviceId = ""
  state.actuatorNodeId = ""
  clearSessionState()
}

const resetStepStatusText = () => {
  renderStatus(elements.connectionStatus, buildStatus({
    summary: "Find the Pi first to load and save its configuration.",
  }))
  renderStatus(elements.cropStatus, buildStatus({
    summary: "Use a built-in crop profile or add a custom one before assigning plant channels.",
  }))
  elements.cropProfileSummary.textContent = "No crop profile selected yet"
  renderStatus(elements.zoneStatus, buildStatus({
    summary: "Create the first bed before flashing the sensor Pico.",
  }))
  renderStatus(elements.sensorDeviceStatus, buildStatus({
    summary: "Click Detect Pico after you plug in the Sensor Pico using BOOTSEL.",
  }))
  elements.sensorDetectedTitle.textContent = "No Pico detected yet"
  elements.sensorDetectedDetail.textContent = "Plug in one Pico in BOOTSEL mode. Use one board at a time."
  elements.plantChannelSettings.replaceChildren()
  elements.savePlantSettings.disabled = true
  renderStatus(elements.plantSettingsStatus, buildStatus({
    summary: "Plant assignments appear after the sensor channels are detected.",
  }))
  renderStatus(elements.sensorStatus, buildStatus({
    summary: "Click Detect Pico after the Sensor Pico appears in BOOTSEL mode.",
  }))
  renderStatus(elements.actuatorDeviceStatus, buildStatus({
    summary: "Click Detect Pico after you plug in the Actuator Pico using BOOTSEL.",
  }))
  elements.actuatorDetectedTitle.textContent = "No Pico detected yet"
  elements.actuatorDetectedDetail.textContent = "Plug in one Pico in BOOTSEL mode. Use one board at a time."
  renderStatus(elements.actuatorStatus, buildStatus({
    summary: "Click Detect Pico after the Actuator Pico appears in BOOTSEL mode.",
  }))
  elements.readingNodeSummary.textContent = "No sensor node assigned yet"
  elements.readingDetailSummary.textContent = "No reading confirmed yet"
  renderStatus(elements.readingStatus, buildStatus({
    summary: "Finish the sensor setup first.",
  }))
  elements.calibrationDrySummary.textContent = "Not captured yet"
  elements.calibrationWetSummary.textContent = "Not captured yet"
  renderStatus(elements.calibrationStatus, buildStatus({
    summary: "Finish the sensor setup before calibration.",
  }))
  elements.wateringZoneSummary.textContent = "No zone ready yet"
  elements.wateringDetailSummary.textContent = "No watering cycle confirmed yet"
  renderStatus(elements.wateringStatus, buildStatus({
    summary: "Finish the actuator setup and wait for the actuator node to come online first.",
  }))
  renderStatus(elements.finishStatus, buildStatus({
    summary: "Finish the setup steps above first.",
  }))
  renderStatus(elements.supportStatus, buildStatus({
    summary: "No diagnostic bundle exported yet.",
  }))
}

const loadPreferences = () => {
  elements.wizardUrl.value = window.localStorage.getItem("vg-installer:wizard-url") || "victory-garden.local"
  elements.picoWifiSsid.value = window.localStorage.getItem("vg-installer:pico-wifi-ssid") || ""
  elements.dryThreshold.value = "30"
  elements.maxPulseRuntime.value = "45"
  elements.dailyMaxRuntime.value = "300"
  elements.zoneFrequencyHours.value = "1"
  elements.sensorChannelCount.value = "4"
}

const normalizedPiUrl = () => {
  return normalizePiUrl(elements.wizardUrl.value, "victory-garden.local")
}

const dashboardUrl = () => {
  const base = state.piVerifiedUrl || normalizedPiUrl()
  const url = new URL(base)
  url.pathname = "/"
  url.search = ""
  url.hash = ""
  return url.toString()
}

const isFinitePositiveInteger = (value, { minimum = 1, maximum = Number.MAX_SAFE_INTEGER } = {}) => (
  Number.isInteger(value) && value >= minimum && value <= maximum
)

const validateConnectionForm = () => {
  if (!elements.picoWifiSsid.value.trim()) {
    return "Enter the Pico Wi-Fi SSID before continuing."
  }

  if (!elements.picoWifiPassword.value) {
    return "Enter the Pico Wi-Fi password before continuing."
  }

  const mqttPort = Number(elements.mqttPort.value)
  if (!isFinitePositiveInteger(mqttPort, { minimum: 1, maximum: 65535 })) {
    return "Enter a valid MQTT port between 1 and 65535."
  }

  const irrigationLineCount = Number(elements.irrigationLineCount.value)
  if (!isFinitePositiveInteger(irrigationLineCount, { minimum: 1, maximum: 128 })) {
    return "Enter how many pump or relay outputs the actuator should manage."
  }

  return null
}

const validateCropProfileForm = () => {
  if (!elements.cropName.value.trim()) {
    return "Enter a crop name before creating the crop profile."
  }

  const dryThreshold = Number(elements.dryThreshold.value)
  if (!Number.isFinite(dryThreshold) || dryThreshold < 0 || dryThreshold > 100) {
    return "Enter a dry threshold between 0 and 100."
  }

  const maxPulseRuntime = Number(elements.maxPulseRuntime.value)
  if (!isFinitePositiveInteger(maxPulseRuntime, { minimum: 1, maximum: 86400 })) {
    return "Enter a valid max pulse runtime in seconds."
  }

  const dailyMaxRuntime = Number(elements.dailyMaxRuntime.value)
  if (!isFinitePositiveInteger(dailyMaxRuntime, { minimum: 1, maximum: 86400 })) {
    return "Enter a valid daily max runtime in seconds."
  }

  if (dailyMaxRuntime < maxPulseRuntime) {
    return "Daily max runtime must be greater than or equal to max pulse runtime."
  }

  return null
}

const validateZoneForm = () => {
  if (!elements.zoneName.value.trim()) {
    return "Enter a bed or zone name before saving."
  }

  const publishIntervalHours = Number(elements.zoneFrequencyHours.value)
  if (!isFinitePositiveInteger(publishIntervalHours, { minimum: 1, maximum: 168 })) {
    return "Enter a reading frequency in whole hours."
  }

  return null
}

const picoProvisioningPayload = (kind) => {
  return buildPicoProvisioningPayload({
    bootstrap: state.bootstrap,
    piVerifiedUrl: state.piVerifiedUrl,
    form: {
      wifiSsid: elements.picoWifiSsid.value,
      wifiPassword: elements.picoWifiPassword.value,
      mqttPort: elements.mqttPort.value,
    },
    kind,
  })
}

const currentDetectedDevice = () => {
  if (state.devices.length !== 1) {
    return null
  }

  return state.devices[0]
}

const friendlyBoardName = (board) => (
  board === "pico2_w" ? "Pico 2 W" : "Pico W"
)

const friendlyKindName = (kind) => (
  kind === "sensor" ? "Sensor Node" : "Actuator Node"
)

const markChip = (element, label, complete) => {
  element.textContent = label
  element.classList.toggle("is-complete", complete)
}

const markPill = (element, label, tone) => {
  element.textContent = label
  element.dataset.tone = tone
}

const setConnectionForm = (connection) => {
  elements.mqttHost.value = connection.mqtt_host || ""
  elements.mqttPort.value = connection.mqtt_port || 1883
  elements.mqttUsername.value = connection.mqtt_username || ""
  elements.mqttUsername.disabled = true
  elements.mqttPassword.value = ""
  elements.mqttPassword.placeholder = connection.provisioning_mqtt_password ? "Managed by the Pi" : "Broker password"
  elements.mqttPassword.disabled = true
  elements.irrigationLineCount.value = connection.irrigation_line_count || ""
}

const setZoneForm = (zone) => {
  if (!zone) {
    return
  }

  elements.zoneName.value = zone.name || ""
  if (zone.publish_interval_ms) {
    elements.zoneFrequencyHours.value = String(Math.max(1, zone.publish_interval_ms / 3600000))
  }
}

const renderPlantChannelSettings = () => {
  if (!elements.plantChannelSettings) {
    return
  }

  const profiles = state.bootstrap?.crop_profiles || []
  const pumpCount = maxPumpOutput()
  const zone = state.bootstrap?.first_zone

  if (!state.channels.length) {
    elements.plantChannelSettings.replaceChildren()
    if (elements.savePlantSettings) {
      elements.savePlantSettings.disabled = true
    }
    elements.plantSettingsStatus.textContent = "Plant assignments appear after the sensor channels are detected."
    return
  }

  const rows = state.channels.map((channel, index) => {
    const row = document.createElement("div")
    row.className = "fact plant-channel-row"
    row.dataset.nodeId = channel.nodeId

    const title = document.createElement("span")
    title.textContent = `A${index}`

    const controls = document.createElement("div")
    controls.className = "plant-channel-controls"

    const nameInput = document.createElement("input")
    nameInput.type = "text"
    nameInput.dataset.plantField = "name"
    nameInput.value = defaultChannelName(channel, index)
    nameInput.placeholder = zone ? `${zone.name || zone.zone_id}_Ch${index + 1}` : `Channel ${index + 1}`

    const cropSelect = document.createElement("select")
    cropSelect.dataset.plantField = "cropProfileId"
    for (const profile of profiles) {
      const option = document.createElement("option")
      option.value = String(profile.id)
      option.textContent = `${profile.crop_name} (${profile.dry_threshold}% dry)`
      cropSelect.appendChild(option)
    }
    if (profiles.length) {
      cropSelect.value = String(channel.cropProfileId || defaultCropProfileId())
    }

    const pumpInput = document.createElement("input")
    pumpInput.type = "number"
    pumpInput.min = "1"
    pumpInput.max = String(Math.max(pumpCount, 1))
    pumpInput.dataset.plantField = "irrigationLine"
    pumpInput.value = String(channel.irrigationLine || index + 1)
    pumpInput.placeholder = String(index + 1)

    controls.append(nameInput, cropSelect, pumpInput)
    row.append(title, controls)
    return row
  })

  elements.plantChannelSettings.replaceChildren(...rows)
  elements.savePlantSettings.disabled = !profiles.length || !zone
  elements.plantSettingsStatus.textContent = allChannelsConfigured()
    ? "Plant assignments are saved for all detected channels."
    : "Review each plant name, crop profile, and pump output, then save assignments."
}

const renderCropProfiles = (profiles) => {
  const currentProfiles = profiles || []
  if (!currentProfiles.length) {
    elements.cropProfileSummary.textContent = "No crop profile created yet"
    renderPlantChannelSettings()
    return
  }

  if (state.selectedCropProfileId && currentProfiles.some((profile) => profile.id === state.selectedCropProfileId)) {
    // Keep the selected profile.
  } else {
    const fallback = currentProfiles[0]
    state.selectedCropProfileId = fallback.id
  }

  const selected = currentProfiles.find((profile) => profile.id === state.selectedCropProfileId)
  elements.cropProfileSummary.textContent = selected
    ? `${selected.crop_name} · ${selected.max_pulse_runtime_sec}s pulse · ${selected.daily_max_runtime_sec}s daily max`
    : "Crop profile ready"
  renderPlantChannelSettings()
}

const restoreSessionState = (session) => {
  if (!session) {
    return
  }

  state.piVerifiedUrl = session.piVerifiedUrl || state.piVerifiedUrl
  state.selectedCropProfileId = session.selectedCropProfileId || state.selectedCropProfileId
  state.sensorDeviceId = session.sensorDeviceId || session.sensorNodeId || state.sensorDeviceId
  state.channels = normalizeChannels(session.channels)
  if (state.channels.length === 0 && session.sensorNodeId) {
    state.channels = normalizeChannels([{
      nodeId: session.sensorNodeId,
      dryRaw: session.calibration?.dryRaw,
      wetRaw: session.calibration?.wetRaw,
    }])
  }
  state.actuatorNodeId = session.actuatorNodeId || state.actuatorNodeId
  state.provisioned = {
    sensor: Boolean(session.provisioned?.sensor || state.provisioned.sensor || state.sensorDeviceId),
    actuator: Boolean(session.provisioned?.actuator || state.provisioned.actuator || state.actuatorNodeId),
  }
  state.completed = {
    sensor: Boolean(session.completed?.sensor || state.completed.sensor),
    actuator: Boolean(session.completed?.actuator || state.completed.actuator),
    reading: Boolean(session.completed?.reading || state.completed.reading),
    calibration: Boolean(session.completed?.calibration || state.completed.calibration),
    watering: Boolean(session.completed?.watering || state.completed.watering),
  }
  state.messages = {
    sensor: session.messages?.sensor || state.messages.sensor,
    actuator: session.messages?.actuator || state.messages.actuator,
  }
  state.wateringAttempt = session.wateringAttempt?.idempotencyKey ? { ...session.wateringAttempt } : null
}

const applyBootstrap = (bootstrap) => {
  state.bootstrap = bootstrap
  const sensorDevice = bootstrap.assigned_node?.channels?.length ? bootstrap.assigned_node : bootstrap.detected_node
  if (sensorDevice?.channels?.length) {
    state.sensorDeviceId = sensorDevice.device_id || sensorDevice.node_id || state.sensorDeviceId
    const existingByNode = new Map(state.channels.map((channel) => [channel.nodeId, channel]))
    state.channels = normalizeChannels(sensorDevice.channels).map((channel) => ({
      ...channel,
      name: channel.name || existingByNode.get(channel.nodeId)?.name || "",
      cropProfileId: channel.cropProfileId ?? existingByNode.get(channel.nodeId)?.cropProfileId ?? defaultCropProfileId(),
      irrigationLine: channel.irrigationLine ?? existingByNode.get(channel.nodeId)?.irrigationLine ?? null,
      wateringConfigured: channel.wateringConfigured || existingByNode.get(channel.nodeId)?.wateringConfigured || false,
      dryRaw: channel.dryRaw ?? existingByNode.get(channel.nodeId)?.dryRaw ?? null,
      wetRaw: channel.wetRaw ?? existingByNode.get(channel.nodeId)?.wetRaw ?? null,
    }))
  }
  state.actuatorNodeId = bootstrap.detected_node?.node_id?.startsWith("actuator-")
    ? bootstrap.detected_node.node_id
    : state.actuatorNodeId
  state.completed.sensor = Boolean(bootstrap.status?.assigned_node_ready) || state.completed.sensor
  state.completed.calibration = Boolean(bootstrap.status?.calibration_ready)
  state.completed.watering = Boolean(bootstrap.status?.watering_ready)
  setConnectionForm(bootstrap.connection_setting)
  renderCropProfiles(bootstrap.crop_profiles)
  setZoneForm(bootstrap.first_zone)
}

const currentResumeStep = () => {
  return nextInstallerStep({
    piVerifiedUrl: state.piVerifiedUrl,
    bootstrap: state.bootstrap,
    completed: state.completed,
    wateringAttempt: state.wateringAttempt,
  })
}

const focusResumeStep = (step) => {
  const section = document.querySelector(`#${step.id}`)
  if (!section) {
    return
  }

  window.setTimeout(() => {
    section.scrollIntoView({ behavior: "smooth", block: "start" })
  }, 50)
}

const connectionReady = () => Boolean(state.bootstrap?.status?.connection_ready)
const zoneReady = () => effectiveFirstZoneReady(state.bootstrap?.status)
const sensorDetectedReady = () => Boolean(state.bootstrap?.status?.detected_node_ready)
const sensorAssignedReady = () => Boolean(state.bootstrap?.status?.assigned_node_ready)
const readingReady = () => state.completed.reading
const calibrationReady = () => Boolean(state.bootstrap?.status?.calibration_ready) || state.completed.calibration
const wateringReady = () => effectiveWateringDone({
  status: state.bootstrap?.status,
  completed: state.completed,
  wateringAttempt: state.wateringAttempt,
})

const formatCalibrationSummary = (value) => (
  Number.isFinite(value) ? `${value} raw avg from 10 readings` : "Not captured yet"
)

const defaultChannelName = (channel, index) => {
  const zoneName = state.bootstrap?.first_zone?.name || state.bootstrap?.first_zone?.zone_id || "Zone"
  return channel.name || `${zoneName}_Ch${index + 1}`
}

const defaultCropProfileId = () => {
  const profiles = state.bootstrap?.crop_profiles || []
  return state.selectedCropProfileId || profiles[0]?.id || null
}

const maxPumpOutput = () => Number(state.bootstrap?.connection_setting?.irrigation_line_count || 0)
const wateringTargetChannel = () => state.channels.find((channel) => (
  channel.nodeId && Number.isFinite(Number(channel.cropProfileId)) && Number.isFinite(Number(channel.irrigationLine))
)) || null

const readingIdentity = (reading) => {
  if (!reading) {
    return null
  }

  if (Number.isFinite(reading.id) && reading.recorded_at) {
    return `id:${reading.id}|at:${reading.recorded_at}`
  }

  if (Number.isFinite(reading.id)) {
    return `id:${reading.id}`
  }

  if (reading.recorded_at) {
    return `at:${reading.recorded_at}`
  }

  return null
}

const updatePiStep = () => {
  const ready = Boolean(state.piVerifiedUrl)
  elements.verifiedUrl.textContent = state.piVerifiedUrl || "Not verified yet"
  elements.saveConnection.disabled = !ready
  elements.createCropProfile.disabled = !ready
  elements.saveZone.disabled = !ready
  elements.requestReading.disabled = !ready
  elements.startWatering.disabled = !ready
  elements.openDashboard.disabled = !ready

  markChip(elements.progressPi, ready ? "Pi Found" : "Pi Not Found", ready)
  markPill(elements.piStepPill, ready ? "Ready" : (state.piChecking ? "Checking" : "Waiting"), ready ? "complete" : (state.piChecking ? "active" : "waiting"))
}

const updateConnectionStep = () => {
  const ready = connectionReady()
  markChip(elements.progressConnection, ready ? "Connection Saved" : "Connection Not Saved", ready)
  markPill(elements.connectionStepPill, ready ? "Done" : "Waiting", ready ? "complete" : "waiting")
}

const updateCropStep = () => {
  const cropReady = Boolean(state.bootstrap?.crop_profiles?.length)
  markPill(elements.cropStepPill, cropReady ? "Ready" : "Waiting", cropReady ? "complete" : "waiting")
}

const updateZoneStep = () => {
  const ready = zoneReady()
  markChip(elements.progressZone, ready ? "Zone Created" : "Zone Not Created", ready)
  markPill(elements.zoneStepPill, ready ? "Done" : "Waiting", ready ? "complete" : "waiting")
}

const updatePicoStep = (kind) => {
  const buttonElement = kind === "sensor" ? elements.sensorFlash : elements.actuatorFlash
  const titleElement = kind === "sensor" ? elements.sensorDetectedTitle : elements.actuatorDetectedTitle
  const detailElement = kind === "sensor" ? elements.sensorDetectedDetail : elements.actuatorDetectedDetail
  const statusElement = kind === "sensor" ? elements.sensorStatus : elements.actuatorStatus
  const detectionStatusElement = kind === "sensor" ? elements.sensorDeviceStatus : elements.actuatorDeviceStatus
  const refreshButton = kind === "sensor" ? elements.refreshSensorDevices : elements.refreshActuatorDevices
  const stepPill = kind === "sensor" ? elements.sensorStepPill : elements.actuatorStepPill
  const progressChip = kind === "sensor" ? elements.progressSensor : elements.progressActuator
  const completed = state.completed[kind]
  const flashing = state.flashing[kind]
  const setupReady = zoneReady()
  const device = currentDetectedDevice()
  const sensorOnline = sensorDetectedReady()
  const sensorAssigned = sensorAssignedReady()
  const provisioned = state.provisioned[kind]

  if (!setupReady) {
    buttonElement.disabled = true
    refreshButton.disabled = true
    statusElement.textContent = state.messages[kind] || "Finish the Pi configuration and first bed before flashing Pico boards."
    detectionStatusElement.textContent = "Finish the Pi configuration and first bed before detecting Pico hardware."
    titleElement.textContent = "Pico setup is locked until earlier steps are complete"
    detailElement.textContent = "The installer saves all required Pi-side information first, then moves to hardware."
    markPill(stepPill, "Locked", "waiting")
    markChip(progressChip, completed ? `${kind === "sensor" ? "Sensor" : "Actuator"} Ready` : `${kind === "sensor" ? "Sensor" : "Actuator"} Not Provisioned`, completed)
    return
  }

  if (completed && !flashing) {
    refreshButton.disabled = false
    statusElement.textContent = state.messages[kind] || (kind === "sensor"
      ? "Sensor firmware installed, the channels connected to the Pi, and they are assigned to the bed."
      : `${friendlyKindName(kind)} firmware is provisioned and online. Continue with reading, calibration, and watering validation here.`)
  }

  if (flashing) {
    buttonElement.disabled = true
    refreshButton.disabled = true
    detectionStatusElement.textContent = "Flashing is in progress. Wait for the BOOTSEL drive to disappear and the Pico to reboot."
    markPill(stepPill, "Flashing", "active")
    markChip(progressChip, `${kind === "sensor" ? "Sensor" : "Actuator"} Provisioning`, false)
    statusElement.textContent = state.messages[kind] || statusElement.textContent
    return
  }

  if (state.devices.length === 0) {
    titleElement.textContent = "No Pico detected yet"
    detailElement.textContent = "Plug in one Pico in BOOTSEL mode. Use one board at a time."
    buttonElement.disabled = true
    refreshButton.disabled = false
    detectionStatusElement.textContent = `Click Detect Pico after you plug in the ${kind === "sensor" ? "Sensor" : "Actuator"} Pico using BOOTSEL.`
    if (!completed && !state.messages[kind]) {
      statusElement.textContent = provisioned && kind === "actuator"
        ? "Actuator firmware is provisioned. Move it to the real actuator hardware and wait for it to appear on the Pi."
        : "Click Detect Pico after you plug a board in using BOOTSEL."
    }
    markPill(stepPill, completed ? "Done" : "Waiting", completed ? "complete" : "waiting")
    const sensorChipLabel = completed || sensorAssigned
      ? "Sensor Connected"
      : (sensorOnline ? "Sensor Detected" : "Sensor Not Flashed")
    markChip(
      progressChip,
      kind === "sensor"
        ? sensorChipLabel
        : (completed ? "Actuator Connected" : (provisioned ? "Actuator Provisioned" : "Actuator Not Provisioned")),
      completed || (kind === "sensor" && sensorAssigned),
    )
    return
  }

  if (state.devices.length > 1) {
    titleElement.textContent = "Multiple Pico boards detected"
    detailElement.textContent = "Unplug all but one BOOTSEL drive before continuing."
    buttonElement.disabled = true
    refreshButton.disabled = false
    detectionStatusElement.textContent = "Multiple BOOTSEL drives were found. Leave only one connected, then click Detect Pico again."
    if (!completed && !state.messages[kind]) {
      statusElement.textContent = "Only one BOOTSEL drive can be used at a time."
    }
    markPill(stepPill, completed ? "Done" : "Resolve", completed ? "complete" : "warning")
    const multipleLabel = kind === "sensor"
      ? (completed || sensorAssigned ? "Sensor Connected" : "Sensor Waiting")
      : (completed ? "Actuator Connected" : (provisioned ? "Actuator Provisioned" : "Actuator Waiting"))
    markChip(progressChip, multipleLabel, completed || (kind === "sensor" && sensorAssigned))
    return
  }

  titleElement.textContent = `${friendlyBoardName(device.board)} detected`
  detailElement.textContent = `Mounted as ${device.volume_name} at ${device.mount_path}. The installer will use ${firmwareNames[kind][device.board]} for this ${friendlyBoardName(device.board)} board.`
  buttonElement.disabled = false
  refreshButton.disabled = false
  detectionStatusElement.textContent = `${friendlyBoardName(device.board)} detected and ready to flash.`
  if (!completed && !state.messages[kind]) {
    statusElement.textContent = kind === "sensor"
      ? "Pico detected. Flash it now. The installer will then wait for the sensor node to join Wi‑Fi, report to the Pi, and assign it automatically."
      : "Pico detected. Flash it now. The installer will provision it, then wait for the actuator node to appear on the Pi."
  }
  markPill(stepPill, completed ? "Done" : "Ready", completed ? "complete" : "active")
  if (kind === "sensor") {
    const label = completed || sensorAssigned ? "Sensor Connected" : (sensorOnline ? "Sensor Detected" : "Sensor Ready")
    markChip(progressChip, label, completed || sensorAssigned)
  } else {
    markChip(progressChip, completed ? "Actuator Connected" : (provisioned ? "Actuator Provisioned" : "Actuator Ready"), completed)
  }
}

const updateReadingStep = () => {
  const readyForReading = state.completed.sensor || sensorAssignedReady()
  const assignedNode = state.bootstrap?.assigned_node
  const readingDone = readingReady()
  const readingInFlight = state.flashing.reading
  const calibrationDone = calibrationReady()

  elements.readingNodeSummary.textContent = assignedNode
    ? `${assignedNode.node_id} -> ${assignedNode.zone_name || state.bootstrap?.first_zone?.name || state.bootstrap?.first_zone?.zone_id}`
    : "No sensor node assigned yet"

  if (!readyForReading || !calibrationDone) {
    elements.requestReading.disabled = true
    elements.readingStatus.textContent = !readyForReading
      ? "Finish the sensor setup first."
      : "Save calibration before confirming the calibrated reading."
    elements.readingDetailSummary.textContent = "No reading confirmed yet"
    markChip(elements.progressReading, readingDone ? "Reading Verified" : "Reading Not Verified", readingDone)
    markPill(elements.readingStepPill, readingDone ? "Done" : "Waiting", readingDone ? "complete" : "waiting")
    return
  }

  elements.requestReading.disabled = readingInFlight
  if (readingDone && elements.readingDetailSummary.textContent === "No reading confirmed yet") {
    elements.readingDetailSummary.textContent = "A fresh reading has already been confirmed on the Pi."
  }
  markChip(elements.progressReading, readingDone ? "Reading Verified" : (readingInFlight ? "Waiting For Reading" : "Reading Not Verified"), readingDone)
  markPill(elements.readingStepPill, readingDone ? "Done" : (readingInFlight ? "Checking" : "Ready"), readingDone ? "complete" : (readingInFlight ? "active" : "waiting"))

  if (!readingDone && !readingInFlight && !elements.readingStatus.textContent.trim()) {
    elements.readingStatus.textContent = "Request an immediate reading after the sensor node is online."
  }
}

const updateCalibrationStep = () => {
  const assignedNode = state.bootstrap?.assigned_node
  const readyForCalibration = state.completed.sensor || sensorAssignedReady()
  const calibrationDone = calibrationReady()
  const calibrationInFlight = state.flashing.calibration

  elements.calibrationDrySummary.textContent = state.channels.length
    ? state.channels.map((channel) => `${channel.nodeId}: ${formatCalibrationSummary(channel.dryRaw)}`).join(" · ")
    : "Not captured yet"
  elements.calibrationWetSummary.textContent = state.channels.length
    ? state.channels.map((channel) => `${channel.nodeId}: ${formatCalibrationSummary(channel.wetRaw)}`).join(" · ")
    : "Not captured yet"
  elements.calibrationChannelProgress.replaceChildren(...state.channels.map((channel, index) => {
    const fact = document.createElement("div")
    fact.className = "fact"
    const label = document.createElement("span")
    label.textContent = `Channel ${index + 1}`
    const value = document.createElement("strong")
    value.textContent = `Dry ${formatCalibrationSummary(channel.dryRaw)} · Wet ${formatCalibrationSummary(channel.wetRaw)}`
    fact.append(label, value)
    return fact
  }))

  if (!readyForCalibration) {
    elements.captureDryCalibration.disabled = true
    elements.captureWetCalibration.disabled = true
    elements.calibrationStatus.textContent = "Finish the sensor setup first."
    markChip(elements.progressCalibration, calibrationDone ? "Calibration Saved" : "Calibration Not Saved", calibrationDone)
    markPill(elements.calibrationStepPill, calibrationDone ? "Done" : "Waiting", calibrationDone ? "complete" : "waiting")
    return
  }

  elements.captureDryCalibration.disabled = calibrationInFlight
  elements.captureWetCalibration.disabled = calibrationInFlight || !allChannelsHave("dryRaw")

  if (!calibrationInFlight && !elements.calibrationStatus.textContent.trim()) {
    elements.calibrationStatus.textContent = assignedNode
      ? "Place all four probes in dry soil and capture one grouped reading."
      : "Place all four probes in dry soil and capture one grouped reading."
  }

  if (!calibrationDone && !calibrationInFlight && allChannelsHave("dryRaw") && !allChannelsHave("wetRaw")) {
    elements.calibrationStatus.textContent = "All four dry values are captured. Move every probe to saturated soil, then capture the grouped wet reading."
  }

  if (calibrationDone && !calibrationInFlight) {
    elements.calibrationStatus.textContent = "Calibration saved. You can recalibrate later anytime in the Victory Garden app."
  }

  markChip(
    elements.progressCalibration,
    calibrationDone ? "Calibration Saved" : (calibrationInFlight ? "Saving Calibration" : "Calibration Not Saved"),
    calibrationDone,
  )
  markPill(
    elements.calibrationStepPill,
    calibrationDone ? "Done" : (calibrationInFlight ? "Capturing" : "Ready"),
    calibrationDone ? "complete" : (calibrationInFlight ? "active" : "waiting"),
  )
}

const updateWateringStep = () => {
  const zone = state.bootstrap?.first_zone
  const target = wateringTargetChannel()
  const canWater = (state.completed.actuator && readingReady() && calibrationReady() && target) || wateringReady()
  const wateringDone = wateringReady()
  const wateringInFlight = state.flashing.watering

  elements.wateringZoneSummary.textContent = target
    ? `${target.name || target.nodeId} -> pump ${target.irrigationLine}`
    : (zone ? `${zone.name || zone.zone_id} needs plant assignments` : "No zone ready yet")

  if (!canWater) {
    elements.startWatering.disabled = true
    elements.wateringStatus.textContent = !state.completed.actuator
      ? "Finish the actuator setup and wait for the actuator node to come online first."
      : (!readingReady()
          ? "Confirm the calibrated reading before testing watering."
          : (!calibrationReady()
              ? "Save the dry and wet calibration before testing watering."
              : "Save plant crop and pump assignments before testing watering."))
    elements.wateringDetailSummary.textContent = "No watering cycle confirmed yet"
    markChip(elements.progressWatering, wateringDone ? "Watering Verified" : "Watering Not Verified", wateringDone)
    markPill(elements.wateringStepPill, wateringDone ? "Done" : "Waiting", wateringDone ? "complete" : "waiting")
    return
  }

  elements.startWatering.disabled = wateringInFlight
  if (wateringDone && elements.wateringDetailSummary.textContent === "No watering cycle confirmed yet") {
    elements.wateringDetailSummary.textContent = "A watering cycle has already been confirmed on the Pi."
  }
  markChip(elements.progressWatering, wateringDone ? "Watering Verified" : (wateringInFlight ? "Waiting For Watering" : "Watering Not Verified"), wateringDone)
  markPill(elements.wateringStepPill, wateringDone ? "Done" : (wateringInFlight ? "Checking" : "Ready"), wateringDone ? "complete" : (wateringInFlight ? "active" : "waiting"))

  if (!wateringDone && !wateringInFlight && !elements.wateringStatus.textContent.trim()) {
    elements.wateringStatus.textContent = "Run one manual watering cycle after the actuator is online."
  }
}

const updateFinishStep = () => {
  const complete = Boolean(state.piVerifiedUrl) && connectionReady() && zoneReady() && state.completed.sensor && state.completed.actuator && readingReady() && calibrationReady() && wateringReady()
  markPill(elements.finishStepPill, complete ? "Ready" : "Waiting", complete ? "complete" : "waiting")
  elements.finishStatus.textContent = complete
    ? "Setup is fully validated. You can hand off to the web dashboard for normal operation."
    : "Finish Pi setup, both Pico hardware steps, the first reading, sensor calibration, and the first watering cycle."
}

const updateUi = () => {
  updatePiStep()
  updateConnectionStep()
  updateCropStep()
  updateZoneStep()
  updatePicoStep("sensor")
  updatePicoStep("actuator")
  updateReadingStep()
  updateCalibrationStep()
  updateWateringStep()
  updateFinishStep()
  saveSessionState()
}

const refreshDevices = async () => {
  if (state.refreshInFlight) {
    return
  }

  state.refreshInFlight = true
  void logInstallerInfo("device", "detect_start", "Starting BOOTSEL device detection.")
  renderStatus(elements.sensorDeviceStatus, buildStatus({
    summary: "Checking for mounted BOOTSEL drives...",
  }))
  renderStatus(elements.actuatorDeviceStatus, buildStatus({
    summary: "Checking for mounted BOOTSEL drives...",
  }))
  elements.refreshSensorDevices.disabled = true
  elements.refreshActuatorDevices.disabled = true

  try {
    const devices = await invoke("detect_bootsel_devices")
    state.devices = devices
    void logInstallerInfo("device", "detect_result", "Completed BOOTSEL device detection.", {
      deviceCount: devices.length,
      devices,
    })
    if (devices.length === 0) {
      const status = buildStatus({
        summary: "No BOOTSEL drives detected.",
        detail: "Put one Pico into BOOTSEL mode, then click Detect Pico again.",
      })
      renderStatus(elements.sensorDeviceStatus, status)
      renderStatus(elements.actuatorDeviceStatus, status)
    } else if (devices.length === 1) {
      const device = devices[0]
      const status = buildStatus({
        summary: `${friendlyBoardName(device.board)} detected as ${device.volume_name}.`,
        detail: `Mounted at ${device.mount_path}.`,
        recovery: "Use this Pico for the current step, or unplug it and insert a different board.",
      })
      renderStatus(elements.sensorDeviceStatus, status)
      renderStatus(elements.actuatorDeviceStatus, status)
    } else {
      const status = buildStatus({
        summary: `${devices.length} BOOTSEL drives detected.`,
        detail: "The installer can only flash one board at a time.",
        recovery: "Unplug all but one BOOTSEL drive, then click Detect Pico again.",
      })
      renderStatus(elements.sensorDeviceStatus, status)
      renderStatus(elements.actuatorDeviceStatus, status)
    }
  } catch (error) {
    state.devices = []
    void logInstallerError("device", "detect_failed", "BOOTSEL device detection failed.", {
      error: asErrorMessage(error),
    })
    const status = buildStatus({
      summary: "Pico detection failed.",
      detail: "The installer could not scan mounted BOOTSEL drives.",
      recovery: "Reconnect the Pico in BOOTSEL mode and try Detect Pico again.",
      technicalDetail: asErrorMessage(error),
    })
    renderStatus(elements.sensorDeviceStatus, status)
    renderStatus(elements.actuatorDeviceStatus, status)
  } finally {
    state.refreshInFlight = false
    elements.refreshSensorDevices.disabled = false
    elements.refreshActuatorDevices.disabled = false
    updateUi()
  }
}

const refreshBootstrapFromPi = async () => {
  if (!state.piVerifiedUrl) {
    return
  }

  const bootstrap = await invokePiApiWithRetry(
    "fetch_setup_bootstrap",
    { baseUrl: state.piVerifiedUrl },
    {
      attempts: 5,
      baseDelayMs: 1500,
      maxDelayMs: 6000,
      timeoutMs: 10000,
      context: "Refreshing setup state from the Pi",
    },
  )
  applyBootstrap(bootstrap)
}

const resumeInstallerSession = async () => {
  const savedSession = loadSessionState()
  if (!savedSession?.piVerifiedUrl) {
    return
  }

  void logInstallerInfo("recovery", "resume_start", "Attempting to resume a previous installer session.", {
    piVerifiedUrl: savedSession.piVerifiedUrl,
    savedAt: savedSession.savedAt,
  })
  restoreSessionState(savedSession)
  if (!elements.wizardUrl.value.trim()) {
    elements.wizardUrl.value = savedSession.piVerifiedUrl
  }

  renderStatus(elements.wizardStatus, buildStatus({
    summary: `Resuming the previous installer session from ${savedSession.piVerifiedUrl}...`,
  }))
  updateUi()

  try {
    const bootstrap = await invokePiApiWithRetry(
      "fetch_setup_bootstrap",
      { baseUrl: savedSession.piVerifiedUrl },
      {
        attempts: 5,
        baseDelayMs: 1500,
        maxDelayMs: 6000,
        timeoutMs: 10000,
        context: "Resuming installer state from the Pi",
        onRetry: ({ attempt, attempts, delayMs, classified }) => {
          renderStatus(elements.wizardStatus, buildStatus({
            summary: `Found a previous installer session at ${savedSession.piVerifiedUrl}.`,
            detail: piRetryDetail(classified, attempt, attempts, delayMs),
          }))
        },
      },
    )

    state.piVerifiedUrl = savedSession.piVerifiedUrl
    elements.wizardUrl.value = savedSession.piVerifiedUrl
    applyBootstrap(bootstrap)

    if (state.provisioned.sensor && !state.completed.sensor && !state.messages.sensor) {
      state.messages.sensor = "Sensor provisioning was restored from the previous installer session. Move the sensor Pico to the real probe hardware, then wait for it to appear on the Pi."
    }

    if (state.provisioned.actuator && !state.completed.actuator && !state.messages.actuator) {
      state.messages.actuator = "Actuator provisioning was restored from the previous installer session. Move the actuator Pico to the real actuator hardware, then wait for it to appear on the Pi."
    }

    const step = currentResumeStep()
    renderStatus(elements.wizardStatus, buildStatus({
      summary: `Resumed the previous installer session from ${savedSession.piVerifiedUrl}.`,
      detail: `Continue with ${step.label}.`,
    }))
    void logInstallerInfo("recovery", "resume_success", "Resumed a previous installer session.", {
      piVerifiedUrl: savedSession.piVerifiedUrl,
      resumeStep: step.label,
    })
    updateUi()
    focusResumeStep(step)
  } catch (error) {
    clearSessionState()
    state.piVerifiedUrl = ""
    const classified = classifyPiDiscoveryError(error, { online: browserOnline() })
    renderStatus(elements.wizardStatus, buildStatus({
      summary: "A previous installer session was found, but the Pi could not be resumed automatically.",
      detail: classified.summary,
      recovery: `Bring the Pi back online, then rerun Find Pi. ${classified.recovery || ""}`.trim(),
      technicalDetail: asErrorMessage(error),
    }))
    void logInstallerWarn("recovery", "resume_failed", "A saved installer session could not be resumed automatically.", {
      piVerifiedUrl: savedSession.piVerifiedUrl,
      error: asErrorMessage(error),
    })
    updateUi()
  }
}

const waitForActuatorNodeReady = async (nodeId, statusElement) => {
  const deadline = Date.now() + 90000

  while (Date.now() < deadline) {
    const response = await invokePiApiWithRetry(
      "fetch_setup_node_status",
      {
        input: {
          baseUrl: state.piVerifiedUrl,
          nodeId,
        },
      },
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          statusElement.textContent = `Provisioned ${nodeId}. Waiting for the Pi to respond again (${attempt}/${attempts})...`
        },
      },
    )

    if (!response.detected) {
      statusElement.textContent = `Provisioned ${nodeId}. Waiting for it to join Wi‑Fi and report to the Pi...`
      await sleep(2000)
      continue
    }

    await refreshBootstrapFromPi()
    state.actuatorNodeId = response.node?.node_id || nodeId
    return response.node || { node_id: nodeId }
  }

  const diagnostics = await fetchRuntimeDiagnostics("actuator")
  const piDiagnostics = await fetchPiNodeDiagnostics(nodeId, "actuator")
  throw new Error(`Provisioned ${nodeId}, but it did not appear in Victory Garden within 90 seconds. ${piDiagnostics} ${describeRuntimeDiagnostics(diagnostics)}`)
}

const fetchRuntimeDiagnostics = async (kind) => {
  try {
    return await invoke("collect_pico_runtime_diagnostics", {
      input: {
        kind,
        timeoutMs: 8000,
      },
    })
  } catch (error) {
    return {
      category: "diagnostics_failed",
      summary: "The installer could not collect Pico runtime diagnostics.",
      detail: String(error),
      recent_lines: [],
      serial_port: null,
    }
  }
}

const describeRuntimeDiagnostics = (diagnostics) => {
  const details = [diagnostics.summary, diagnostics.detail]
  if (diagnostics.serial_port) {
    details.push(`Serial port: ${diagnostics.serial_port}.`)
  }
  if (diagnostics.recent_lines?.length) {
    details.push(`Recent Pico logs: ${diagnostics.recent_lines.join(" | ")}`)
  }
  return details.filter(Boolean).join(" ")
}

const summarizePiNodeStatus = (statusResponse, kind, nodeId) => {
  if (!statusResponse || !statusResponse.detected || !statusResponse.node) {
    return `${friendlyKindName(kind)} ${nodeId} has not appeared on the Pi yet.`
  }

  const node = statusResponse.node
  const details = [`${friendlyKindName(kind)} ${node.node_id} is visible to the Pi.`]

  if (node.last_seen_at) {
    details.push(`Last seen: ${node.last_seen_at}.`)
  }

  if (node.config_status) {
    details.push(`Config status: ${node.config_status}.`)
  }

  if (node.reported_zone_id) {
    details.push(`Reported zone: ${node.reported_zone_id}.`)
  }

  if (kind === "sensor") {
    details.push(node.assigned
      ? `Assigned to ${node.zone_name || "a zone"}.`
      : "It is not assigned to a zone yet.")
  }

  return details.join(" ")
}

const fetchPiNodeDiagnostics = async (nodeId, kind) => {
  if (!state.piVerifiedUrl || !nodeId) {
    return ""
  }

  try {
    const response = await invokePiApiWithRetry(
      "fetch_setup_node_status",
      {
        input: {
          baseUrl: state.piVerifiedUrl,
          nodeId,
        },
      },
      {
        attempts: 2,
        delayMs: 1000,
      },
    )
    return summarizePiNodeStatus(response, kind, nodeId)
  } catch (error) {
    return `The installer also could not read ${friendlyKindName(kind)} status from the Pi: ${asErrorMessage(error)}`
  }
}

const fetchPiWateringDiagnostics = async (zoneId, idempotencyKey = "", nodeId = "") => {
  if (!state.piVerifiedUrl || !zoneId) {
    return ""
  }

  try {
    const status = await invokePiApiWithRetry(
      "fetch_setup_watering_status",
      {
        input: {
          baseUrl: state.piVerifiedUrl,
          zoneId,
          nodeId,
          idempotencyKey,
        },
      },
      {
        attempts: 2,
        delayMs: 1000,
      },
    )

    const details = []
    if (status.event) {
      details.push(`Latest watering event status: ${status.event.status}.`)
      if (status.event.reason) {
        details.push(`Reason: ${status.event.reason}.`)
      }
      if (status.event.issued_at) {
        details.push(`Issued at: ${status.event.issued_at}.`)
      }
    } else {
      details.push("The Pi has no watering event recorded for this validation yet.")
    }

    if (status.actuator_status) {
      details.push(`Latest actuator status: ${status.actuator_status.state}.`)
      if (status.actuator_status.recorded_at) {
        details.push(`Actuator status time: ${status.actuator_status.recorded_at}.`)
      }
    } else {
      details.push("The Pi has not recorded any actuator status yet.")
    }

    return details.join(" ")
  } catch (error) {
    return `The installer also could not read watering status from the Pi: ${asErrorMessage(error)}`
  }
}

const waitForSensorNodeReady = async (channelIds, statusElement) => {
  const zone = state.bootstrap?.first_zone
  if (!zone) {
    throw new Error("The first bed is missing. Save the bed before provisioning the sensor.")
  }
  const expectedChannelCount = await expectedSensorChannelCount()
  if (channelIds.length !== expectedChannelCount) {
    throw new Error(`The sensor Pico reported ${channelIds.length} channels; expected ${expectedChannelCount}.`)
  }

  const deadline = Date.now() + 90000
  while (Date.now() < deadline) {
    const responses = await Promise.all(channelIds.map((nodeId) => invokePiApiWithRetry(
      "fetch_setup_node_status",
      { input: { baseUrl: state.piVerifiedUrl, nodeId } },
      { attempts: 4, delayMs: 2000 },
    )))

    const detectedCount = responses.filter((response) => response.detected).length
    if (detectedCount !== channelIds.length) {
      statusElement.textContent = `Detected ${detectedCount} of ${channelIds.length} sensor channels. Waiting for the remaining state messages...`
      await sleep(2000)
      continue
    }

    if (responses.some((response) => !response.assigned || response.node?.zone_id !== zone.id)) {
      statusElement.textContent = `All four channels detected. Assigning device to ${zone.name || zone.zone_id}...`
      await invokePiApiWithRetry(
        "assign_setup_node",
        {
          input: {
            baseUrl: state.piVerifiedUrl,
            nodeId: channelIds[0],
            zoneId: zone.id,
          },
        },
        {
          attempts: 4,
          delayMs: 2000,
          onRetry: ({ attempt, attempts }) => {
            statusElement.textContent = `Waiting for the Pi to assign the sensor device (${attempt}/${attempts})...`
          },
        },
      )
      await sleep(500)
      continue
    }

    await refreshBootstrapFromPi()
    state.channels = normalizeChannels(responses.map((response) => response.node))
    return responses.map((response) => response.node)
  }

  const diagnostics = await fetchRuntimeDiagnostics("sensor")
  const piDiagnostics = await fetchPiNodeDiagnostics(channelIds[0], "sensor")
  throw new Error(`Provisioned sensor channels did not all appear in Victory Garden within 90 seconds. ${piDiagnostics} ${describeRuntimeDiagnostics(diagnostics)}`)
}

const readPlantAssignmentsFromUi = () => {
  const rows = [...elements.plantChannelSettings.querySelectorAll("[data-node-id]")]
  return rows.map((row, index) => ({
    nodeId: row.dataset.nodeId,
    name: row.querySelector("[data-plant-field='name']")?.value.trim() || defaultChannelName(state.channels[index], index),
    cropProfileId: Number(row.querySelector("[data-plant-field='cropProfileId']")?.value),
    irrigationLine: Number(row.querySelector("[data-plant-field='irrigationLine']")?.value),
  }))
}

const validatePlantAssignments = (assignments) => {
  const pumpCount = maxPumpOutput()
  if (!state.bootstrap?.first_zone) {
    return "Create the bed before saving plant assignments."
  }
  if (!assignments.length) {
    return "Detect the sensor channels before saving plant assignments."
  }
  if (!(state.bootstrap?.crop_profiles || []).length) {
    return "Create or seed at least one crop profile before saving plant assignments."
  }

  const seenPumpOutputs = new Set()
  for (const assignment of assignments) {
    if (!assignment.name) {
      return "Every plant channel needs a name."
    }
    if (!isFinitePositiveInteger(assignment.cropProfileId)) {
      return `Choose a crop profile for ${assignment.nodeId}.`
    }
    if (!isFinitePositiveInteger(assignment.irrigationLine, { minimum: 1, maximum: pumpCount || 128 })) {
      return `Choose a valid pump output for ${assignment.nodeId}.`
    }
    if (seenPumpOutputs.has(assignment.irrigationLine)) {
      return `Pump output ${assignment.irrigationLine} is assigned to more than one plant.`
    }
    seenPumpOutputs.add(assignment.irrigationLine)
  }

  return null
}

const savePlantSettings = async () => {
  const assignments = readPlantAssignmentsFromUi()
  const validationError = validatePlantAssignments(assignments)
  if (validationError) {
    renderStatus(elements.plantSettingsStatus, buildStatus({
      summary: "Plant assignments are incomplete.",
      detail: validationError,
      recovery: "Review the plant rows, then save assignments again.",
    }))
    return
  }

  elements.savePlantSettings.disabled = true
  renderStatus(elements.plantSettingsStatus, buildStatus({
    summary: "Saving plant assignments...",
  }))

  try {
    const responses = await Promise.all(assignments.map((assignment) => invokePiApiWithRetry(
      "update_setup_node",
      {
        input: {
          baseUrl: state.piVerifiedUrl,
          nodeId: assignment.nodeId,
          name: assignment.name,
          cropProfileId: assignment.cropProfileId,
          irrigationLine: assignment.irrigationLine,
        },
      },
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          elements.plantSettingsStatus.textContent = `Waiting for the Pi to save plant assignments (${attempt}/${attempts})...`
        },
      },
    )))

    const responseByNode = new Map(responses.map((response) => [response.node.node_id, response.node]))
    state.channels = state.channels.map((channel, index) => {
      const saved = responseByNode.get(channel.nodeId)
      return saved ? normalizeChannels([saved])[0] : { ...channel, ...assignments[index] }
    })
    renderStatus(elements.plantSettingsStatus, buildStatus({
      summary: "Plant assignments saved.",
      detail: "Each channel now has its own crop profile and pump output.",
    }))
    await refreshBootstrapFromPi()
  } catch (error) {
    renderStatus(
      elements.plantSettingsStatus,
      piApiFailureStatus(
        "Saving plant assignments",
        error,
        "The Pi rejected the plant assignment update.",
        "Check that pump outputs are within the configured count and are not duplicated, then retry.",
      ),
    )
  } finally {
    elements.savePlantSettings.disabled = false
    updateUi()
  }
}

const waitForFreshReading = async (nodeId, requestedAt, { onWaiting } = {}) => {
  const deadline = Date.now() + 90000

  while (Date.now() < deadline) {
    const status = await invokePiApiWithRetry(
      "fetch_setup_reading_status",
      {
        input: {
          baseUrl: state.piVerifiedUrl,
          nodeId,
          since: requestedAt,
        },
      },
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          if (onWaiting) {
            onWaiting(`Waiting for the Pi to respond again (${attempt}/${attempts})...`)
          }
        },
      },
    )

    if (status.complete && status.reading) {
      return status.reading
    }

    if (onWaiting) {
      onWaiting(`Waiting for ${nodeId} to publish a fresh reading...`)
    }
    await sleep(2000)
  }

  throw new Error(`Timed out waiting for a fresh reading from ${nodeId}.`)
}

const requestFirstReading = async () => {
  const nodeId = primarySensorNodeId()
  const channelIds = channelNodeIds()
  if (!nodeId || channelIds.length === 0) {
    renderStatus(elements.readingStatus, buildStatus({
      summary: "No assigned sensor node is available yet.",
      recovery: "Finish the sensor Pico step and wait for the node to appear on the Pi.",
    }))
    return
  }

  if (!calibrationReady()) {
    renderStatus(elements.readingStatus, buildStatus({
      summary: "Calibration is not saved yet.",
      recovery: "Capture and save dry and wet calibration before confirming the calibrated reading.",
    }))
    return
  }

  state.flashing.reading = true
  state.completed.reading = false
  updateUi()
  void logInstallerInfo("reading", "request_start", "Starting first reading validation.", {
    nodeId,
  })
  elements.readingStatus.textContent = `Requesting an immediate reading from ${nodeId}...`

  try {
    const queued = await invokePiApiWithRetry(
      "request_setup_reading",
      {
        input: {
          baseUrl: state.piVerifiedUrl,
          nodeId,
        },
      },
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          elements.readingStatus.textContent = `Waiting for the Pi to respond so it can queue the reading request (${attempt}/${attempts})...`
        },
      },
    )
    const readings = await Promise.all(channelIds.map((channelId) => waitForFreshReading(channelId, queued.requested_at, {
      onWaiting: () => {
        elements.readingStatus.textContent = `Waiting for fresh readings from all ${channelIds.length} channels...`
      },
    })))
    const readingsMissingEnvironment = readings.filter((reading) => (
      !Number.isFinite(Number(reading.air_temperature_c)) ||
      !Number.isFinite(Number(reading.humidity_percent)) ||
      !reading.greenhouse_alert_status
    ))
    if (readingsMissingEnvironment.length > 0) {
      const details = readingsMissingEnvironment
        .map((reading) => `${reading.node_id}: ${reading.last_error || "missing SHT40 fields"}`)
        .join(" · ")
      throw new Error(`Fresh readings arrived, but SHT40 temperature/humidity was missing. ${details}`)
    }

    state.completed.reading = true
    elements.readingDetailSummary.textContent = readings
      .map((reading) => `${reading.node_id}: ${reading.moisture_percent ?? "—"}%, air ${formatTemperatureF(Number(reading.air_temperature_c))}, RH ${formatHumidity(Number(reading.humidity_percent))}`)
      .join(" · ")
    elements.readingStatus.textContent = `Confirmed fresh readings and SHT40 data from all ${channelIds.length} channels.`
    void logInstallerInfo("reading", "request_success", "Confirmed fresh readings from all sensor channels.", {
      channelIds,
      readings,
    })
    await refreshBootstrapFromPi()
  } catch (error) {
    state.completed.reading = false
    void logInstallerError("reading", "request_failed", "First reading validation failed.", {
      nodeId,
      error: asErrorMessage(error),
    })
    const classified = classifyPiConnectivityError(error, { online: browserOnline() })
    renderStatus(
      elements.readingStatus,
      classified.category !== "unknown"
        ? piApiFailureStatus(
            "Reading validation",
            error,
            "The installer could not confirm a fresh reading from the assigned sensor node.",
            "Make sure the Pi is reachable again, then retry this step.",
          )
        : buildStatus({
            summary: "Reading validation failed.",
            detail: "The installer could not confirm a fresh reading from the assigned sensor node.",
            recovery: "Make sure the sensor Pico is on the real hardware and still online, then retry this step.",
            technicalDetail: asErrorMessage(error),
          }),
    )
  } finally {
    state.flashing.reading = false
    updateUi()
  }
}

const captureCalibration = async (target) => {
  const nodeId = primarySensorNodeId()
  const channelIds = channelNodeIds()

  if (!nodeId || channelIds.length === 0) {
    renderStatus(elements.calibrationStatus, buildStatus({
      summary: "No assigned sensor node is available yet.",
      recovery: "Finish the sensor Pico step before calibration.",
    }))
    return
  }

  state.flashing.calibration = true
  state.completed.calibration = false
  updateUi()
  void logInstallerInfo("calibration", "capture_start", "Starting calibration capture.", {
    channelIds,
    target,
  })

  const targetLabel = target === "dry" ? "dry soil" : "saturated soil"
  try {
    elements.calibrationStatus.textContent = `Requesting one ${targetLabel} reading from all ${channelIds.length} channels...`
    const queued = await invokePiApiWithRetry(
      "request_setup_reading",
      { input: { baseUrl: state.piVerifiedUrl, nodeId } },
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          elements.calibrationStatus.textContent = `Waiting for the Pi to queue the grouped reading (${attempt}/${attempts})...`
        },
      },
    )
    const readings = await Promise.all(channelIds.map((channelId) => waitForFreshReading(channelId, queued.requested_at, {
      onWaiting: () => {
        elements.calibrationStatus.textContent = `Waiting for ${targetLabel} readings from all ${channelIds.length} channels...`
      },
    })))
    const readingsByNode = new Map(readings.map((reading) => [reading.node_id, reading]))
    const rawKey = target === "dry" ? "dryRaw" : "wetRaw"
    state.channels = state.channels.map((channel) => ({
      ...channel,
      [rawKey]: readingsByNode.get(channel.nodeId)?.moisture_raw ?? channel[rawKey],
    }))
    saveSessionState()

    void logInstallerInfo("calibration", `${target}_captured`, `Captured grouped ${target} calibration readings.`, {
      readings,
    })

    if (target === "dry") {
      elements.calibrationStatus.textContent = "Captured all four dry values. Move every probe to saturated soil, then capture wet."
    }

    if (!allChannelsHave("dryRaw") || !allChannelsHave("wetRaw")) {
      return
    }

    elements.calibrationStatus.textContent = "Saving calibration for all four channels..."
    const responses = await Promise.all(state.channels.map((channel) => invokePiApiWithRetry(
      "save_setup_calibration",
      { input: {
        baseUrl: state.piVerifiedUrl,
        nodeId: channel.nodeId,
        moistureRawDry: channel.dryRaw,
        moistureRawWet: channel.wetRaw,
      } },
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          elements.calibrationStatus.textContent = `Waiting for the Pi to respond so it can save the calibration (${attempt}/${attempts})...`
        },
      },
    )))

    state.completed.calibration = responses.every((response) => response.node.calibration_configured)
    elements.calibrationStatus.textContent = "Saved individual dry and wet calibration for all four channels."
    void logInstallerInfo("calibration", "save_success", "Saved all channel calibrations to the Pi.", {
      channels: state.channels,
    })
    await refreshBootstrapFromPi()
  } catch (error) {
    state.completed.calibration = false
    void logInstallerError("calibration", "capture_failed", "Calibration failed.", {
      nodeId,
      target,
      error: asErrorMessage(error),
    })
    const classified = classifyPiConnectivityError(error, { online: browserOnline() })
    renderStatus(
      elements.calibrationStatus,
      classified.category !== "unknown"
        ? piApiFailureStatus(
            "Calibration",
            error,
            "The installer could not capture or save a full dry and wet calibration set.",
            "Wait for the Pi to respond again, then retry the current calibration target.",
          )
        : buildStatus({
            summary: "Calibration failed.",
            detail: "The installer could not capture or save a full dry and wet calibration set.",
            recovery: "Verify the sensor node is still online and publishing fresh readings, then retry the current calibration target.",
            technicalDetail: asErrorMessage(error),
          }),
    )
  } finally {
    state.flashing.calibration = false
    updateUi()
  }
}

const waitForWateringCompletion = async (zone, target, idempotencyKey = "") => {
  const deadline = Date.now() + 120000

  while (Date.now() < deadline) {
    const status = await invokePiApiWithRetry(
      "fetch_setup_watering_status",
      buildWateringStatusRequest({
        baseUrl: state.piVerifiedUrl,
        zoneId: zone.id,
        nodeId: target?.nodeId || "",
        attempt: { idempotencyKey },
      }),
      {
        attempts: 4,
        delayMs: 2000,
        onRetry: ({ attempt, attempts }) => {
          elements.wateringStatus.textContent = `Waiting for the Pi to respond again (${attempt}/${attempts})...`
        },
      },
    )
    const classification = classifyWateringStatus(status, idempotencyKey)

    if (classification.state === "success") {
      state.completed.watering = true
      state.wateringAttempt = {
        idempotencyKey,
        zoneId: zone.id,
        nodeId: target?.nodeId || "",
        status: "completed",
        outcome: classification.outcome,
      }
      saveSessionState()
      const actuatorState = status.actuator_status?.state || status.event.status
      elements.wateringDetailSummary.textContent = `${actuatorState} at ${status.event.issued_at || "unknown time"}`
      elements.wateringStatus.textContent = `Confirmed a completed watering cycle for ${target?.name || target?.nodeId || zone.name || zone.zone_id}.`
      await refreshBootstrapFromPi()
      return
    }

    if (classification.state === "recovery") {
      state.completed.watering = false
      state.wateringAttempt = {
        idempotencyKey,
        zoneId: zone.id,
        nodeId: target?.nodeId || "",
        status: "recovery",
        outcome: classification.outcome,
      }
      saveSessionState()
      throw new Error(`${classification.message} ${classification.recovery}`.trim())
    }

    const currentState = status.actuator_status?.state || status.event?.status || "waiting"
    elements.wateringStatus.textContent = `Waiting for the actuator to finish watering (${currentState})...`
    await sleep(2000)
  }

  throw new Error(`Timed out waiting for the watering cycle on ${target?.name || target?.nodeId || zone.name || zone.zone_id}.`)
}

const runFirstWatering = async () => {
  const zone = state.bootstrap?.first_zone
  const target = wateringTargetChannel()
  if (!zone) {
    renderStatus(elements.wateringStatus, buildStatus({
      summary: "No zone is configured yet.",
      recovery: "Create and save the first bed before testing watering.",
    }))
    return
  }

  if (!target) {
    renderStatus(elements.wateringStatus, buildStatus({
      summary: "No plant watering target is configured yet.",
      recovery: "Save plant crop and pump assignments before testing watering.",
    }))
    return
  }

  state.flashing.watering = true
  state.completed.watering = false
  state.wateringAttempt = null
  saveSessionState()
  updateUi()
  void logInstallerInfo("watering", "start", "Starting watering validation.", {
    zoneId: zone.id,
    zoneName: zone.name || zone.zone_id,
    nodeId: target.nodeId,
    pumpOutput: target.irrigationLine,
  })
  elements.wateringStatus.textContent = `Starting a watering cycle for ${target.name || target.nodeId}...`

  let queued = null
  try {
    try {
      queued = await invokePiApiWithRetry(
        "start_setup_watering",
        {
          input: {
            baseUrl: state.piVerifiedUrl,
            zoneId: zone.id,
            nodeId: target.nodeId,
          },
        },
        {
          attempts: 4,
          delayMs: 2000,
          onRetry: ({ attempt, attempts }) => {
            elements.wateringStatus.textContent = `Waiting for the Pi to respond so it can start watering (${attempt}/${attempts})...`
          },
        },
      )
    } catch (error) {
      const message = String(error)
      if (!message.includes("Watering is already active for this target.")) {
        throw error
      }

      void logInstallerWarn("watering", "uncorrelated_active_cycle", "Cannot reuse an active watering cycle without its idempotency key.", {
        zoneId: zone.id,
        zoneName: zone.name || zone.zone_id,
        nodeId: target.nodeId,
      })
      throw new Error(`A watering cycle is already active for ${target.name || target.nodeId}, but this installer session does not have its idempotency key. Inspect the actuator state and retry deliberately when safe.`)
    }

    state.wateringAttempt = wateringAttemptFromStartResponse(queued, {
      zoneId: zone.id,
      nodeId: target.nodeId,
    })
    saveSessionState()
    await waitForWateringCompletion(zone, target, queued.idempotency_key)
    void logInstallerInfo("watering", "success", "Watering validation completed successfully.", {
      zoneId: zone.id,
      zoneName: zone.name || zone.zone_id,
      nodeId: target.nodeId,
      idempotencyKey: queued.idempotency_key,
    })
  } catch (error) {
    state.completed.watering = false
    const diagnostics = await fetchRuntimeDiagnostics("actuator")
    const piDiagnostics = await fetchPiWateringDiagnostics(zone.id, queued?.idempotency_key || "", target.nodeId)
    const actuatorNodeDiagnostics = await fetchPiNodeDiagnostics(state.actuatorNodeId, "actuator")
    void logInstallerError("watering", "failed", "Watering validation failed.", {
      zoneId: zone.id,
      zoneName: zone.name || zone.zone_id,
      nodeId: target.nodeId,
      error: asErrorMessage(error),
      piDiagnostics,
      actuatorNodeDiagnostics,
      runtimeDiagnostics: diagnostics,
    })
    const classified = classifyPiConnectivityError(error, { online: browserOnline() })
    renderStatus(
      elements.wateringStatus,
      classified.category !== "unknown"
        ? piApiFailureStatus(
            "Watering validation",
            error,
            "The installer could not confirm a completed watering cycle for the selected plant.",
            "Wait for the Pi to respond again, then retry watering validation.",
          )
        : buildStatus({
            summary: "Watering validation failed.",
            detail: "The installer could not confirm a completed watering cycle for the selected plant.",
            recovery: "Make sure the actuator Pico is on the real actuator hardware, online, and still visible to the Pi, then retry watering validation.",
            technicalDetail: [asErrorMessage(error), piDiagnostics, actuatorNodeDiagnostics, describeRuntimeDiagnostics(diagnostics)].filter(Boolean).join(" "),
          }),
    )
  } finally {
    state.flashing.watering = false
    updateUi()
  }
}

const findPi = async () => {
  resetInstallerState()
  resetStepStatusText()
  state.piChecking = true
  savePreferences()
  updateUi()
  void logInstallerInfo("pi", "find_start", "Starting Pi discovery.", {
    wizardUrl: elements.wizardUrl.value.trim(),
  })
  renderStatus(elements.wizardStatus, buildStatus({
    summary: "Looking for the Victory Garden app on the Pi...",
  }))

  try {
    const url = normalizedPiUrl()
    const probe = await probePiWithRetry(url, {
      attempts: 6,
      baseDelayMs: 1000,
      maxDelayMs: 8000,
      timeoutMs: 10000,
      onRetry: ({ attempt, attempts, delayMs, classified }) => {
        renderStatus(elements.wizardStatus, buildStatus({
          summary: "Looking for the Victory Garden app on the Pi...",
          detail: piRetryDetail(classified, attempt, attempts, delayMs),
        }))
      },
    })
    const bootstrap = await invokePiApiWithRetry("fetch_setup_bootstrap", { baseUrl: probe.url }, {
      attempts: 6,
      baseDelayMs: 1000,
      maxDelayMs: 8000,
      timeoutMs: 10000,
      context: "Loading setup state from the Pi",
      onRetry: ({ attempt, attempts, delayMs, classified }) => {
        renderStatus(elements.wizardStatus, buildStatus({
          summary: `Pi found at ${probe.url}, but setup data is not ready yet.`,
          detail: piRetryDetail(classified, attempt, attempts, delayMs),
        }))
      },
    })
    state.piVerifiedUrl = probe.url
    elements.wizardUrl.value = probe.url
    applyBootstrap(bootstrap)
    renderStatus(elements.wizardStatus, buildStatus({
      summary: `Pi found at ${probe.url}.`,
      detail: "The installer loaded the current setup state from the Pi.",
    }))
    void logInstallerInfo("pi", "find_success", "Pi discovery succeeded.", {
      probeUrl: probe.url,
      statusCode: probe.status_code,
    })
    renderStatus(elements.connectionStatus, buildStatus({
      summary: bootstrap.status.connection_ready
        ? "Connection settings are already saved on the Pi."
        : "Connection settings are loaded. Save them here to continue.",
    }))
    renderStatus(elements.cropStatus, buildStatus({
      summary: bootstrap.crop_profiles.length
        ? "At least one crop profile already exists."
        : "Create a crop profile here, or seed the defaults on the Pi.",
    }))
    renderStatus(elements.zoneStatus, buildStatus({
      summary: bootstrap.first_zone
        ? "A first bed already exists on the Pi."
        : "Save the first bed here.",
    }))
  } catch (error) {
    const classified = classifyPiDiscoveryError(error, { online: browserOnline() })
    renderStatus(elements.wizardStatus, buildStatus({
      summary: classified.summary,
      detail: classified.detail,
      recovery: classified.recovery,
      technicalDetail: asErrorMessage(error),
    }))
    void logInstallerError("pi", "find_failed", "Pi discovery failed.", {
      error: asErrorMessage(error),
      classified,
    })
  } finally {
    state.piChecking = false
    updateUi()
  }
}

const saveConnection = async () => {
  if (!state.piVerifiedUrl) {
    renderStatus(elements.connectionStatus, buildStatus({
      summary: "Find the Pi first.",
      recovery: "Run Step 1 before saving connection settings.",
    }))
    return
  }

  const validationError = validateConnectionForm()
  if (validationError) {
    renderStatus(elements.connectionStatus, buildStatus({
      summary: "Connection settings are incomplete.",
      detail: validationError,
      recovery: "Correct the highlighted values in Step 2, then save again.",
    }))
    return
  }

  renderStatus(elements.connectionStatus, buildStatus({
    summary: "Saving connection settings...",
  }))

  try {
    const response = await invokePiApiWithRetry("save_setup_connection", {
      input: {
        baseUrl: state.piVerifiedUrl,
        mqttHost: elements.mqttHost.value.trim(),
        mqttPort: Number(elements.mqttPort.value),
        mqttUsername: elements.mqttUsername.value.trim(),
        mqttPassword: elements.mqttPassword.value,
        irrigationLineCount: Number(elements.irrigationLineCount.value),
      },
    }, {
      attempts: 4,
      baseDelayMs: 2000,
      maxDelayMs: 8000,
      timeoutMs: 10000,
      context: "Saving connection settings to the Pi",
      onRetry: ({ attempt, attempts, delayMs, classified }) => {
        renderStatus(elements.connectionStatus, buildStatus({
          summary: "Saving connection settings...",
          detail: piRetryDetail(classified, attempt, attempts, delayMs),
        }))
      },
    })

    state.bootstrap = {
      ...(state.bootstrap || {}),
      status: response.status,
      connection_setting: response.connection_setting,
      crop_profiles: state.bootstrap?.crop_profiles || [],
      first_zone: state.bootstrap?.first_zone || null,
      detected_node: state.bootstrap?.detected_node || null,
      assigned_node: state.bootstrap?.assigned_node || null,
    }
    renderStatus(elements.connectionStatus, buildStatus({
      summary: "Connection settings saved.",
      detail: "The installer can now create crop and zone data for the Pi.",
    }))
  } catch (error) {
    renderStatus(
      elements.connectionStatus,
      piApiFailureStatus(
        "Saving connection settings",
        error,
        "The Pi did not accept the setup connection update.",
        "Verify the Pi is still reachable, then retry this step.",
      ),
    )
  } finally {
    updateUi()
  }
}

const createCropProfile = async () => {
  if (!state.piVerifiedUrl) {
    renderStatus(elements.cropStatus, buildStatus({
      summary: "Find the Pi first.",
      recovery: "Run Step 1 before creating a crop profile.",
    }))
    return
  }

  const validationError = validateCropProfileForm()
  if (validationError) {
    renderStatus(elements.cropStatus, buildStatus({
      summary: "Crop profile values are incomplete.",
      detail: validationError,
      recovery: "Correct the crop profile fields, then try again.",
    }))
    return
  }

  renderStatus(elements.cropStatus, buildStatus({
    summary: "Creating crop profile...",
  }))

  try {
    const response = await invokePiApiWithRetry("create_setup_crop_profile", {
      input: {
        baseUrl: state.piVerifiedUrl,
        cropName: elements.cropName.value.trim(),
        dryThreshold: Number(elements.dryThreshold.value),
        maxPulseRuntimeSec: Number(elements.maxPulseRuntime.value),
        dailyMaxRuntimeSec: Number(elements.dailyMaxRuntime.value),
      },
    }, {
      attempts: 4,
      baseDelayMs: 2000,
      maxDelayMs: 8000,
      timeoutMs: 10000,
      context: "Creating the crop profile on the Pi",
      onRetry: ({ attempt, attempts, delayMs, classified }) => {
        renderStatus(elements.cropStatus, buildStatus({
          summary: "Creating crop profile...",
          detail: piRetryDetail(classified, attempt, attempts, delayMs),
        }))
      },
    })

    state.bootstrap = {
      ...(state.bootstrap || {}),
      status: response.status,
      connection_setting: state.bootstrap?.connection_setting,
      crop_profiles: response.crop_profiles,
      first_zone: state.bootstrap?.first_zone || null,
      detected_node: state.bootstrap?.detected_node || null,
      assigned_node: state.bootstrap?.assigned_node || null,
    }
    state.selectedCropProfileId = response.crop_profile.id
    renderCropProfiles(response.crop_profiles)
    renderStatus(elements.cropStatus, buildStatus({
      summary: `Created crop profile ${response.crop_profile.crop_name}.`,
      detail: "You can now assign it to individual plant channels.",
    }))
  } catch (error) {
    renderStatus(
      elements.cropStatus,
      piApiFailureStatus(
        "Creating the crop profile",
        error,
        "The Pi rejected the crop profile request.",
        "Verify the values and Pi connectivity, then retry this step.",
      ),
    )
  } finally {
    updateUi()
  }
}

const saveZone = async () => {
  if (!state.piVerifiedUrl) {
    renderStatus(elements.zoneStatus, buildStatus({
      summary: "Find the Pi first.",
      recovery: "Run Step 1 before saving the first bed.",
    }))
    return
  }

  const validationError = validateZoneForm()
  if (validationError) {
    renderStatus(elements.zoneStatus, buildStatus({
      summary: "Bed values are incomplete.",
      detail: validationError,
      recovery: "Correct the bed fields, then try again.",
    }))
    return
  }

  renderStatus(elements.zoneStatus, buildStatus({
    summary: "Saving first bed...",
  }))

  try {
    const response = await invokePiApiWithRetry("save_setup_zone", {
      input: {
        baseUrl: state.piVerifiedUrl,
        name: elements.zoneName.value.trim(),
        publishIntervalHours: Number(elements.zoneFrequencyHours.value),
      },
    }, {
      attempts: 4,
      baseDelayMs: 2000,
      maxDelayMs: 8000,
      timeoutMs: 10000,
      context: "Saving the first bed to the Pi",
      onRetry: ({ attempt, attempts, delayMs, classified }) => {
        renderStatus(elements.zoneStatus, buildStatus({
          summary: "Saving first bed...",
          detail: piRetryDetail(classified, attempt, attempts, delayMs),
        }))
      },
    })

    state.bootstrap = {
      ...(state.bootstrap || {}),
      status: response.status,
      connection_setting: state.bootstrap?.connection_setting,
      crop_profiles: state.bootstrap?.crop_profiles || [],
      first_zone: response.first_zone,
      detected_node: state.bootstrap?.detected_node || null,
      assigned_node: state.bootstrap?.assigned_node || null,
    }
    renderStatus(elements.zoneStatus, buildStatus({
      summary: `Saved first bed ${response.first_zone.name || response.first_zone.zone_id}.`,
      detail: "The installer can now move on to Pico hardware setup and plant-channel assignments.",
    }))
  } catch (error) {
    renderStatus(
      elements.zoneStatus,
      piApiFailureStatus(
        "Saving the first bed",
        error,
        "The Pi rejected the zone setup request.",
        "Verify the zone fields and Pi connectivity, then retry this step.",
      ),
    )
  } finally {
    updateUi()
  }
}

const flashBoard = async (kind) => {
  const device = currentDetectedDevice()
  const statusElement = kind === "sensor" ? elements.sensorStatus : elements.actuatorStatus

  if (!device) {
    renderStatus(statusElement, buildStatus({
      summary: "No single Pico is ready to provision.",
      detail: "The installer needs exactly one detected BOOTSEL drive for this step.",
      recovery: "Connect one Pico in BOOTSEL mode, click Detect Pico, then retry.",
    }))
    return
  }

  state.flashing[kind] = true
  state.completed[kind] = false
  state.provisioned[kind] = false
  state.messages[kind] = ""
  updateUi()
  void logInstallerInfo("hardware", "flash_start", `Starting ${kind} Pico flash and provisioning.`, {
    kind,
    device,
  })
  state.messages[kind] = `Flashing ${firmwareNames[kind][device.board]} to the detected ${friendlyBoardName(device.board)}.`
  statusElement.textContent = state.messages[kind]

  try {
    const result = await invoke("flash_firmware", { kind, board: device.board })
    void logInstallerInfo("hardware", "flash_complete", `${kind} Pico flash completed.`, result)
    state.messages[kind] = `Installed ${result.flashed_filename}. Waiting for the Pico USB serial port so the installer can provision it.`
    statusElement.textContent = state.messages[kind]
    const provisioned = await invoke("provision_pico", {
      input: picoProvisioningPayload(kind),
    })
    void logInstallerInfo("hardware", "provision_complete", `${kind} Pico provisioning completed.`, provisioned)
    state.provisioned[kind] = true
    if (kind === "sensor") {
      state.sensorDeviceId = provisioned.node_id
      state.channels = normalizeChannels(provisioned.channels)
      state.messages.sensor = `Sensor ${provisioned.node_id} was provisioned with ${state.channels.length} channels. Move it to the real probe hardware while the installer waits for all channels to appear on the Pi.`
    } else {
      state.actuatorNodeId = provisioned.node_id
      state.messages.actuator = `Actuator ${provisioned.node_id} was provisioned. Move it to the real actuator hardware while the installer waits for it to appear on the Pi.`
    }
    saveSessionState()

    if (kind === "sensor") {
      const onlineNodes = await waitForSensorNodeReady(channelNodeIds(), statusElement)
      state.completed[kind] = true
      state.messages[kind] = `All ${onlineNodes.length} channels for ${provisioned.node_id} are online and assigned to ${onlineNodes[0]?.zone_name || state.bootstrap?.first_zone?.name || state.bootstrap?.first_zone?.zone_id}.`
      saveSessionState()
      void logInstallerInfo("hardware", "sensor_online", "All sensor channels are online and assigned.", {
        channelIds: channelNodeIds(),
        zoneName: onlineNodes[0]?.zone_name || state.bootstrap?.first_zone?.name || state.bootstrap?.first_zone?.zone_id,
      })
      statusElement.textContent = state.messages[kind]
    } else {
      const onlineNode = await waitForActuatorNodeReady(provisioned.node_id, statusElement)
      state.actuatorNodeId = onlineNode.node_id || provisioned.node_id
      state.completed[kind] = true
      state.messages[kind] = `Actuator ${onlineNode.node_id || provisioned.node_id} is online. Move on to reading, calibration, and watering validation.`
      saveSessionState()
      void logInstallerInfo("hardware", "actuator_online", "Actuator Pico is online.", {
        nodeId: onlineNode.node_id || provisioned.node_id,
      })
      statusElement.textContent = state.messages[kind]
    }
  } catch (error) {
    state.completed[kind] = false
    state.messages[kind] = `Provisioning failed. Technical detail: ${asErrorMessage(error)}`
    void logInstallerError("hardware", "provision_failed", `${kind} Pico provisioning failed.`, {
      kind,
      error: asErrorMessage(error),
    })
    renderStatus(statusElement, buildStatus({
      summary: `${friendlyKindName(kind)} provisioning failed.`,
      detail: "The installer could not finish the flash, serial provisioning, or online validation sequence for this Pico.",
      recovery: "Reconnect the Pico in BOOTSEL mode if needed, then retry after checking the Pi and hardware wiring.",
      technicalDetail: asErrorMessage(error),
    }))
  } finally {
    state.flashing[kind] = false
    await sleep(1500)
    await refreshDevices()
  }
}

const openDashboard = async () => {
  const url = dashboardUrl()

  try {
    await invoke("open_url", { url })
    void logInstallerInfo("finish", "open_dashboard", "Opened Victory Garden dashboard in the external browser.", {
      url,
    })
    renderStatus(elements.finishStatus, buildStatus({
      summary: `Opened ${url} in your browser.`,
      detail: "Victory Garden setup is complete. Use the web dashboard for normal operation.",
    }))
  } catch (error) {
    void logInstallerError("finish", "open_dashboard_failed", "Failed to open the Victory Garden dashboard automatically.", {
      url,
      error: asErrorMessage(error),
    })
    renderStatus(elements.finishStatus, buildStatus({
      summary: `Could not open ${url} automatically.`,
      detail: "The installer finished, but the dashboard browser handoff failed.",
      recovery: `Open ${url} manually in your browser.`,
      technicalDetail: asErrorMessage(error),
    }))
  }
}

const exportDiagnostics = async () => {
  renderStatus(elements.supportStatus, buildStatus({
    summary: "Preparing a diagnostic bundle...",
    detail: "The installer is packaging logs and current setup state for support.",
  }))
  void logInstallerInfo("support", "export_start", "Starting diagnostic export.")

  try {
    const result = await invoke("export_support_bundle", {
      input: {
        setupState: installerSetupState(),
      },
    })
    void logInstallerInfo("support", "export_success", "Diagnostic export completed.", result)
    renderStatus(elements.supportStatus, buildStatus({
      summary: "Diagnostic bundle exported.",
      detail: `ZIP: ${result.zip_path}`,
      recovery: "Attach this ZIP to your bug report or support request.",
    }))
  } catch (error) {
    void logInstallerError("support", "export_failed", "Diagnostic export failed.", {
      error: asErrorMessage(error),
    })
    renderStatus(elements.supportStatus, buildStatus({
      summary: "Diagnostic export failed.",
      detail: "The installer could not package a support bundle.",
      recovery: "Retry the export. If it still fails, capture the current screen and report the failure message.",
      technicalDetail: asErrorMessage(error),
    }))
  }
}

const bindEvents = () => {
  elements.wizardUrl.addEventListener("change", savePreferences)
  elements.picoWifiSsid.addEventListener("change", savePreferences)
  elements.plantChannelSettings.addEventListener("input", (event) => {
    const row = event.target.closest("[data-node-id]")
    const field = event.target.dataset.plantField
    if (!row || !field) {
      return
    }

    const channel = state.channels.find((item) => item.nodeId === row.dataset.nodeId)
    if (!channel) {
      return
    }

    if (field === "name") {
      channel.name = event.target.value
    } else if (field === "cropProfileId") {
      channel.cropProfileId = Number(event.target.value)
      state.selectedCropProfileId = channel.cropProfileId
    } else if (field === "irrigationLine") {
      channel.irrigationLine = Number(event.target.value)
    }
    saveSessionState()
  })
  elements.findPi.addEventListener("click", () => {
    void findPi()
  })
  elements.saveConnection.addEventListener("click", () => {
    void saveConnection()
  })
  elements.createCropProfile.addEventListener("click", () => {
    void createCropProfile()
  })
  elements.saveZone.addEventListener("click", () => {
    void saveZone()
  })
  elements.savePlantSettings.addEventListener("click", () => {
    void savePlantSettings()
  })
  elements.sensorFlash.addEventListener("click", () => {
    void flashBoard("sensor")
  })
  elements.actuatorFlash.addEventListener("click", () => {
    void flashBoard("actuator")
  })
  elements.requestReading.addEventListener("click", () => {
    void requestFirstReading()
  })
  elements.captureDryCalibration.addEventListener("click", () => {
    void captureCalibration("dry")
  })
  elements.captureWetCalibration.addEventListener("click", () => {
    void captureCalibration("wet")
  })
  elements.startWatering.addEventListener("click", () => {
    void runFirstWatering()
  })
  elements.refreshSensorDevices.addEventListener("click", () => {
    void refreshDevices()
  })
  elements.refreshActuatorDevices.addEventListener("click", () => {
    void refreshDevices()
  })
  elements.openDashboard.addEventListener("click", () => {
    void openDashboard()
  })
  elements.exportDiagnostics.addEventListener("click", () => {
    void exportDiagnostics()
  })
}

const initializeInstaller = async () => {
  loadPreferences()
  resetStepStatusText()
  bindEvents()
  updateUi()

  if (!state.bootstrap) {
    renderCropProfiles([])
  }

  await resumeInstallerSession()
}

void initializeInstaller()
