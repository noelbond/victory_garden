import "@hotwired/turbo-rails"
import "chartkick"
import "Chart.bundle"

let wizardPollTimer = null
const picoFlasherHelperBaseUrl = "http://127.0.0.1:48123/v1"

const bindReadingHistoryFilters = () => {
  document.querySelectorAll("[data-reading-history-filters-shell]").forEach((shell) => {
    if (window.matchMedia("(max-width: 980px)").matches) {
      shell.open = false
    } else {
      shell.open = true
    }
  })

  document.querySelectorAll("[data-reading-history-auto-submit]").forEach((input) => {
    input.addEventListener("change", () => {
      input.form?.requestSubmit()
    }, { once: true })
  })

  document.querySelectorAll("[data-reading-history-timeframe]").forEach((input) => {
    const form = input.form
    const customRange = form?.querySelector("[data-reading-history-custom-range]")
    if (!form || !customRange) return

    const syncCustomRangeVisibility = () => {
      const showCustomRange = input.value === "custom"
      customRange.hidden = !showCustomRange
    }

    syncCustomRangeVisibility()

    input.addEventListener("change", () => {
      const showCustomRange = input.value === "custom"
      customRange.hidden = !showCustomRange

      if (!showCustomRange) {
        form.requestSubmit()
      }
    })
  })
}

const bindAppNav = () => {
  document.querySelectorAll("[data-app-nav-menu]").forEach((menu) => {
    if (window.matchMedia("(max-width: 720px)").matches) {
      menu.open = false
    } else {
      menu.open = true
    }
  })
}

const setActiveZoneNavTarget = (target) => {
  if (!target) return

  document.querySelectorAll("[data-zone-nav-target]").forEach((link) => {
    link.classList.toggle("active", link.dataset.zoneNavTarget === target)
  })
}

const clearActiveZoneNavTargets = () => {
  document.querySelectorAll("[data-zone-nav-target]").forEach((link) => {
    link.classList.remove("active")
  })
}

const closeMobileZoneNavs = () => {
  document.querySelectorAll("[data-zone-side-nav-mobile]").forEach((nav) => {
    nav.open = false
  })
}

const bindZoneNavState = () => {
  document.querySelectorAll("[data-zone-nav-target]").forEach((link) => {
    if (link.dataset.zoneNavBound == "true") return

    link.dataset.zoneNavBound = "true"
    link.addEventListener("click", () => {
      if (link.dataset.turboFrame === "zone_workspace") {
        setActiveZoneNavTarget(link.dataset.zoneNavTarget)
      }

      closeMobileZoneNavs()
    })
  })

  const workspaceFrame = document.querySelector("turbo-frame#zone_workspace[data-zone-workspace-target]")
  if (workspaceFrame?.dataset.zoneWorkspaceTarget) {
    setActiveZoneNavTarget(workspaceFrame.dataset.zoneWorkspaceTarget)
  } else if (document.querySelector("[data-zone-nav-target].active")) {
    // keep server-rendered active zone section state
  } else {
    clearActiveZoneNavTargets()
  }
}

const clearWizardPollTimer = () => {
  if (!wizardPollTimer) return

  window.clearTimeout(wizardPollTimer)
  wizardPollTimer = null
}

const bindWizardPolling = () => {
  clearWizardPollTimer()

  const shell = document.querySelector("[data-wizard-poll-url][data-wizard-poll-interval-ms]")
  if (!shell) return

  const url = shell.dataset.wizardPollUrl
  const intervalMs = Number(shell.dataset.wizardPollIntervalMs)
  if (!url || Number.isNaN(intervalMs) || intervalMs <= 0) return

  wizardPollTimer = window.setTimeout(() => {
    Turbo.visit(url, { action: "replace" })
  }, intervalMs)
}

const bindOnboardingZoneDraftSync = () => {
  const zoneForm = document.querySelector("[data-onboarding-zone-form]")
  const cropProfileForm = document.querySelector("[data-onboarding-crop-profile-form]")
  if (!zoneForm || !cropProfileForm) return

  const syncDraftFields = () => {
    cropProfileForm.querySelectorAll("[data-zone-draft-field]").forEach((hiddenField) => {
      const fieldName = hiddenField.dataset.zoneDraftField
      if (!fieldName) return

      const sourceField = zoneForm.querySelector(`[name="zone[${fieldName}]"]`)
      if (!sourceField) return

      hiddenField.value = sourceField.value
    })
  }

  syncDraftFields()

  zoneForm.querySelectorAll("input, select, textarea").forEach((field) => {
    field.addEventListener("input", syncDraftFields)
    field.addEventListener("change", syncDraftFields)
  })

  cropProfileForm.addEventListener("submit", syncDraftFields)
}

const bindOnboardingGuides = () => {
  document.querySelectorAll("[data-onboarding-guide]").forEach((guide) => {
    const guideKey = guide.dataset.onboardingGuide
    if (!guideKey) return

    const storageKey = `vg-onboarding-guide:${guideKey}`
    const steps = Array.from(guide.querySelectorAll("[data-guide-step]"))
    if (steps.length === 0) return

    const render = (currentIndex) => {
      steps.forEach((step, index) => {
        step.hidden = index > currentIndex
        step.classList.toggle("done", index < currentIndex)
        step.classList.toggle("active", index === currentIndex)
      })
    }

    const readIndex = () => {
      const stored = Number(window.localStorage.getItem(storageKey))
      if (Number.isNaN(stored) || stored < 0) return 0

      return Math.min(stored, steps.length - 1)
    }

    const writeIndex = (index) => {
      window.localStorage.setItem(storageKey, String(index))
      render(index)
    }

    render(readIndex())

    guide.querySelectorAll("[data-guide-complete]").forEach((button) => {
      button.addEventListener("click", () => {
        const step = button.closest("[data-guide-step]")
        const currentIndex = steps.indexOf(step)
        if (currentIndex < 0) return

        writeIndex(Math.min(currentIndex + 1, steps.length - 1))
      })
    })

    guide.querySelectorAll("[data-guide-reset]").forEach((button) => {
      button.addEventListener("click", () => {
        window.localStorage.removeItem(storageKey)
        render(0)
      })
    })
  })
}

const bindPicoFlasherHelper = () => {
  document.querySelectorAll("[data-pico-flasher-shell]").forEach((shell) => {
    const statusValue = shell.querySelector("[data-pico-flasher-status-value]")
    const statusCopy = shell.querySelector("[data-pico-flasher-status-copy]")
    const deviceList = shell.querySelector("[data-pico-flasher-devices]")
    const refreshButton = shell.querySelector("[data-pico-flasher-refresh]")
    const flashButtons = Array.from(shell.querySelectorAll("[data-pico-flash-button]"))

    const setStatus = (label, copy) => {
      if (statusValue) statusValue.textContent = label
      if (statusCopy) statusCopy.textContent = copy
    }

    const renderDevices = (devices) => {
      if (!deviceList) return
      if (!devices.length) {
        deviceList.innerHTML = "<div class=\"muted\">No BOOTSEL drive is mounted yet.</div>"
        return
      }

      deviceList.innerHTML = devices.map((device) => (
        `<div class="wizard-fact"><span>${device.board}</span><strong>${device.mount_path}</strong></div>`
      )).join("")
    }

    const fetchStatus = async () => {
      try {
        const response = await fetch(`${picoFlasherHelperBaseUrl}/status`)
        if (!response.ok) throw new Error(`status ${response.status}`)
        const payload = await response.json()
        const devices = payload.devices || []
        setStatus("Helper Ready", devices.length ? "The desktop helper is running and can see BOOTSEL devices." : "The desktop helper is running. Put a Pico into BOOTSEL mode to enable flashing.")
        renderDevices(devices)
        flashButtons.forEach((button) => {
          const expectedBoard = button.dataset.picoFlashBoard
          const matchingDevice = devices.find((device) => device.board === expectedBoard)
          button.disabled = !matchingDevice
          button.dataset.picoFlashReady = matchingDevice ? "true" : "false"
        })
      } catch (_error) {
        setStatus("Helper Offline", "Start the local desktop helper from your Mac, then refresh this card. The browser cannot flash BOOTSEL drives by itself.")
        renderDevices([])
        flashButtons.forEach((button) => {
          button.disabled = true
          button.dataset.picoFlashReady = "false"
        })
      }
    }

    flashButtons.forEach((button) => {
      if (button.dataset.picoFlashBound === "true") return
      button.dataset.picoFlashBound = "true"

      button.addEventListener("click", async () => {
        const kind = button.dataset.picoFlashKind
        const board = button.dataset.picoFlashBoard
        const firmwarePath = button.dataset.picoFlashPath
        if (!kind || !board || !firmwarePath) return

        const firmwareUrl = new URL(firmwarePath, window.location.origin).toString()
        button.disabled = true
        setStatus("Flashing", `Flashing ${kind} firmware to the detected ${board} BOOTSEL device.`)

        try {
          const response = await fetch(`${picoFlasherHelperBaseUrl}/flash`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ kind, board, firmware_url: firmwareUrl })
          })
          const payload = await response.json()
          if (!response.ok || !payload.ok) {
            throw new Error(payload.error || `status ${response.status}`)
          }

          setStatus("Flash Complete", `${payload.flashed_filename} was copied to ${payload.device.mount_path}. The Pico should reboot automatically now.`)
        } catch (error) {
          setStatus("Flash Failed", error.message || "The helper could not flash the selected board.")
        } finally {
          await fetchStatus()
        }
      })
    })

    if (refreshButton && refreshButton.dataset.picoFlasherBound !== "true") {
      refreshButton.dataset.picoFlasherBound = "true"
      refreshButton.addEventListener("click", () => {
        void fetchStatus()
      })
    }

    void fetchStatus()
  })
}

document.addEventListener("turbo:load", () => {
  bindAppNav()
  bindReadingHistoryFilters()
  bindZoneNavState()
  bindWizardPolling()
  bindOnboardingZoneDraftSync()
  bindOnboardingGuides()
  bindPicoFlasherHelper()
})

document.addEventListener("turbo:frame-load", (event) => {
  if (event.target.id !== "zone_workspace") return

  const target = event.target.dataset.zoneWorkspaceTarget
  if (target) {
    setActiveZoneNavTarget(target)
  } else {
    clearActiveZoneNavTargets()
  }
  closeMobileZoneNavs()
})

document.addEventListener("turbo:before-cache", () => {
  clearWizardPollTimer()
})
