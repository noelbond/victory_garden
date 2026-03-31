# Victory Garden — Kanban (Full Roadmap)

---

## Backlog (Later / Do Not Touch Yet)

### Multi-Zone + Scaling

- Multi-zone support (multiple node_ids)
- Zone grouping / greenhouse abstraction
- Concurrent watering safeguards (avoid pressure drop)
- Per-zone scheduling windows

### Advanced Features

- Weather integration (skip watering if rain forecast)
- Historical analytics (trends, charts)
- Smart calibration (auto-adjust dry/wet thresholds)
- Notifications (email/SMS on faults)

### UI Polish

- [x] Dashboard overview page
- [x] Graphs for moisture over time
- [x] Mobile-friendly layout
- [x] Zone status indicators (OK / watering / fault)

### Operational Follow-Up

- Rotate the LAN Wi-Fi password and update local Pi/Pico credentials after removing the committed secret from the repo

---

## This Week (Core System Completion)

### Contract + Data Consistency

- Define MQTT contract (topics + payloads)
- Create `docs/mqtt.md`
- Standardize node_id format
- Add example MQTT messages

### Sensor + Firmware Alignment

- Normalize moisture readings (raw → 0–100)
- Align firmware payload with contract
- Set publish interval (30–60s)
- Verify clean MQTT output via mosquitto_sub

### Control Loop (Pi)

- Implement MQTT subscriber (Python)
- Log incoming readings clearly
- Implement threshold logic (moisture < X)
- Publish watering command

### Actuation (Critical Gap)

- Implement actuator controller (relay/pump)
- Subscribe to watering command
- Trigger relay ON/OFF
- Add safety timeout (max duration)
- Publish actuator status (complete/fault)

---

## Today (Max 2 tasks — update daily)

- [x] Add example MQTT messages
- [x] Verify actuator timeout / fault path

---

## In Progress (ONLY ONE TASK)

- [ ] Hardware completion:
  - verify the real sensor -> decision -> actuator -> reread loop on hardware
  - confirm the physical actuator trigger and stop path
  - confirm unattended one-zone operation on the live setup

---

## Blocked

- Physical hardware validation:
  - moisture sensor wiring to Pico
  - actuator hardware trigger/stop confirmation on the real device
  - unattended one-zone validation on the live setup

## Done (Completed Foundation)

- Mosquitto running on Pi
- Basic MQTT pub/sub working
- Firmware reading moisture
- Python controller structure exists
- Rails app scaffolded (models + routes)
- Core decision logic implemented (tests passing)

---

# NEXT PHASE — End-to-End Completion (Do After Core Loop Works)

## Integration (Full Vertical Slice)

- Verify full loop:
  - dry soil → publish → decision → water → stop
- Validate reread flow after watering
- Ensure moisture increases after watering
- Confirm system stops correctly

## Safety + Reliability

- Add cooldown logic (no rapid re-trigger)
- Enforce daily runtime cap (verify on hardware)
- Handle duplicate MQTT messages
- Handle missing/stale sensor data
- Handle MQTT reconnects (Pi + firmware)
- Prevent watering if no recent reading

---

# RAILS INTEGRATION (Control Plane)

## Data Ingestion

- MQTT → Rails ingest endpoint
- Store sensor readings (node_id, moisture, timestamp)
- Store watering events
- Store actuator status + faults

## UI (Operator View)

- Show current moisture per zone
- Show last watering time
- Show watering history
- Show actuator status (OK / fault)
- Show “why watering happened” (reason)

## Configuration

- Store thresholds per zone/crop
- Store daily runtime caps
- Publish config to MQTT (or make accessible to Pi)

## Manual Controls

- “Water now” button
- “Stop watering” button

---

# HARDENING (Make it trustworthy)

## Failure Handling

- Sensor returns invalid values → ignore/log
- No readings for X minutes → mark stale
- Actuator fails → publish fault + stop retries
- Prevent infinite watering loop

## Idempotency

- Handle duplicate watering commands safely
- Handle repeated actuator status messages

## Observability

- Add structured logging (Pi controller)
- Add event logs (why watering triggered/skipped)
- Add debug mode for troubleshooting

---

# OPEN SOURCE COMPLETION

## Documentation

- `docs/architecture.md` (final system design)
- `docs/mqtt.md` (contract — already started)
- Setup guide (Pi + firmware + Rails)
- Wiring diagrams (sensor + relay + pump)
- Calibration guide (dry/wet values)

## Usability

- Example `.env` / config files
- Seed data for Rails
- One-zone quick start guide

## Demo

- Screenshots of UI
- Example MQTT messages
- Optional: short demo video

---

# FINAL COMPLETION CHECKLIST

- [ ] One zone works fully unattended
- [ ] Sensor → MQTT → decision → actuator → reread loop verified
- [ ] Actuator physically triggers and stops correctly
- [x] Rails shows live state + history
- [x] Configurable thresholds work
- [x] System survives restart (Pi + MQTT + node)
- [x] No rapid re-triggering or infinite loops
- [x] Another person can replicate from docs

---

# Daily Log

## 2026-03-31

- Completed:
  - Defined the canonical MQTT contract in `docs/mqtt.md`
  - Added `docs/architecture.md` and aligned the main documentation set with the current runtime roles
  - Added `docs/setup.md` for Pi deployment, local Rails workflow, Pico SDK setup, and verification steps
  - Added `docs/quickstart.md` for the one-zone bring-up path
  - Added `docs/configuration.md` covering env files, local wrappers, and node config locations
  - Added `docs/calibration.md` describing the current dry/wet calibration model, Arduino support, and the current Pico limitation
  - Added `docs/wiring.md` documenting the real Pico sensor pin assumptions and the current actuator hook boundary
  - Added `docs/seed-data.md` documenting the default Rails seed set
  - Added example MQTT messages for node state, reread command, command ack, node config, config ack, actuator command, actuator status, and controller event
  - Standardized remaining planning terminology from `device_id` to `node_id`
  - Fixed the local Rails environment to use project-local gems via `vendor/bundle`
  - Added local `./bin/dev-bundle` and `./bin/dev-rails` wrappers
  - Added structured JSON logging for the Python controller and actuator lifecycle
  - Added Rails tests for `CommandPublishJob`, `ActuatorCommandTimeoutJob`, `ActuatorStatusIngestor`, and the dry-reading-to-reread full loop
  - Added Rails cooldown protection for automatic watering decisions
  - Made actuator status ingest idempotent for repeated status messages
  - Made sensor ingest ignore duplicate node-state payloads for the same node and timestamp
  - Added stale-reading guardrails so old retained node state is persisted for visibility but cannot trigger automatic watering
  - Prevented `nodes.last_seen_at` from moving backwards when older node-state payloads arrive
  - Surfaced stale claimed readings more clearly in the health-page attention state
  - Added a full-loop test proving a low reread inside the cooldown window does not re-trigger watering
  - Verified the Rails-side actuator timeout, stale-data handling, duplicate handling, cooldown, and dry-soil full loop in tests
  - Reviewed the documentation set for consistency and clarified that Arduino supports explicit dry/wet calibration while Pico currently uses simple ADC scaling plus optional inversion
  - Documented the current wiring assumptions without inventing a fake fixed relay pin map
  - Removed machine-specific Pico build assumptions from the docs so the toolchain and serial examples are portable
  - Smoke-checked the documented Rails and Python entrypoints against the current repo layout
  - Upgraded the root zones page into a real dashboard overview with live zone metrics, watering state, and fault visibility
  - Added a Rails integration test covering the dashboard overview page
  - Reworked the zone detail page into an operator view with top-level reading freshness, actuator state, open-fault visibility, and direct controls
  - Added a Rails integration test covering stale-reading, fault, and active-watering visibility on the zone page
  - Tightened the operator-page CSS for narrow screens so nav, cards, and action groups remain usable on mobile
  - Added a moisture trend chart and history summary to the zone page so the chart section is more useful to operators
  - Added a simple 24-hour and 7-day zone summary so recent moisture and watering behavior is readable without digging through charts
  - Added Rails integration smoke coverage for the documented local operator path: root dashboard, onboarding, health, and zone status/history pages
  - Added an explicit Rails test proving the same moisture value produces different watering decisions for different crop thresholds
  - Promoted the software-verified checklist items: Rails live state/history, configurable thresholds, and no rapid re-triggering
  - Added `ruby_service/bin/dev-smoke` as a single local verification command for the documented Rails/operator workflow
  - Verified `./bin/dev-smoke` against the real local Postgres-backed Rails setup
  - Closed the software-only replication/handoff pass so the remaining open work is explicitly hardware-bound
  - Shifted control authority so Python is now the sole automatic watering controller and Rails remains UI, persistence, config publication, and manual ops
  - Added Rails ingest for Python controller events so automatic watering runs still persist as `WateringEvent` history
  - Switched the Python controller to consume retained `greenhouse/system/config/current` as its live policy source, including `allowed_hours`
  - Removed the dead Rails automatic-decision path from `SensorIngestor`
  - Added MQTT username/password auth support across the Pi install, Rails publishers/consumer, Python controller/actuator, and Pico firmware defaults
  - Applied and verified the Rails `connection_settings` MQTT-auth migration locally, including test-database coverage
  - Removed the committed Pico Wi-Fi password from tracked defaults and added untracked `config_local.h` overrides
  - Hardened Pico string extraction to handle escaped JSON strings in command/config payloads
- Blockers:
  - Physical end-to-end validation still depends on real sensor wiring to the Pico and real actuator hardware confirmation
  - Wi-Fi password rotation still needs to happen on the actual network and devices
- Next:
  - keep the remaining unchecked items limited to hardware validation instead of expanding the software scope
