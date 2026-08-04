# Manual Test Log — Watchdog / Relay Safety Hardening

There is no automated test suite for this firmware (no CI, no unit tests —
just the standalone `*_smoke_test.c`/`*_combo_test.c`/`*_sequence_test.c`
bring-up binaries meant to be flashed and observed by a person). Every claim
in this log was validated only by compiling/linking; runtime behavior needs
to be checked on real hardware by whoever flashes it. Each section below is
one reviewable piece of the watchdog/relay-safety work, in order. Fill in the
`Result` line and date when you've run it.

Applies to: `pico_w_actuator_node` and `pico_w_combined_node` (both changed
identically unless noted).

---

## Piece 1 — relay forced OFF before any networking, at every boot

**What changed:** a new `actuator_relays_init_safe(config)` runs at the very
top of `main()`, before Wi-Fi/MQTT, driving every configured relay GPIO to
its safe OFF level with the anti-glitch ordering (latch preloaded before the
pin becomes an output). Previously this only happened inside `mqtt_node_init()`,
which runs *after* the initial Wi-Fi connect attempt completes — so a relay
sat undriven from power-on until Wi-Fi came up. Also incidentally fixes the
actuator node's own `mqtt_node_init()`, which was missing the anti-glitch
ordering the combined node already had.

**Setup:**
- Board wired to its relay(s) as normal, USB serial attached
  (`screen /dev/cu.usbmodemXXXX 115200`), relay board's own per-channel LED
  (if it has one) or a multimeter on the relay coil/drive line visible.

**Test A — boot ordering (no special equipment, just the serial log):**
1. Power-cycle the board.
2. Read the serial log in order. Confirm `[actuator] relays forced to safe
   OFF level pre-network active_high=...` appears **before** `[wifi]
   connecting ssid=...`.
3. Pass: the safe-init line is always first, on every boot, including when
   Wi-Fi is unreachable (pull the AP/router power first and confirm the
   safe-init line still prints immediately, well before any wifi retry
   logging).

**Test B — no click / no false-energize at power-up:**
1. With a relay physically wired to something inert (no pump/valve attached,
   or one you're fine cycling), power-cycle the board 5-10 times.
2. Watch/listen at the relay itself (its LED and/or the audible click).
3. Pass: the relay never clicks, lights, or otherwise energizes during boot
   before you issue a `start_watering` command. It should stay visibly OFF
   the entire time, including the several seconds before Wi-Fi/MQTT connect.
4. Repeat with Wi-Fi unreachable (router off) so the board sits retrying for
   30+ seconds — confirm the relay stays OFF that whole time, not just at
   the instant of boot.

**Test C — regression check (does normal watering still work):**
1. Once connected, send a normal `start_watering` command for a short
   `runtime_seconds` (e.g. 5s) via your usual MQTT path.
2. Confirm the relay energizes on command and de-energizes at the end of the
   runtime, same as before this change.
3. Pass: no behavior change to the actual watering path — this piece only
   touches what happens *before* a command is ever received.

**Test D — reboot mid-nowhere (approximates the watchdog case):**
1. While idle (no active run), send the `reboot` command over MQTT (or power
   cycle).
2. Confirm relay stays OFF through the reboot and reconnect, same as Test A/B.
3. This doesn't exercise an actual watchdog-timeout reset (hard to trigger
   deterministically), but it exercises the same boot path a watchdog reset
   would take, so it's the closest approximation without hardware to force a
   real hang.

**Result:** _(fill in: pass/fail per board, date, who ran it)_
- `pico_w_actuator_node`: not yet run
- `pico_w_combined_node`: not yet run — blocked on provisioning. The desktop
  installer doesn't support the `combined` role yet (`firmware_filename()` in
  `desktop_installer/src-tauri/src/main.rs` only matches `sensor`/`actuator`
  and errors on anything else), so this board can't be provisioned through
  the normal flow. Live testing deferred until either (a) the installer
  gains combined-role support, or (b) `VG_PROVISION` is sent manually over
  serial. Board is currently flashed and sitting in the USB provisioning
  wait loop (`VG_READY {"role":"combined",...,"requires_provisioning":true}`).

---

## Piece 2 — independent hardware-timer cutoff for irrigation runs

**What changed:** when a `start_watering` command begins a run, in addition
to the existing software `hard_deadline` (checked once per main-loop pass
via `mqtt_node_poll()`), the firmware now also schedules a hardware alarm
(`add_alarm_in_ms`) for the same deadline. That alarm fires from an
interrupt independent of whatever the main loop is doing and immediately
drives the relay GPIO off — so a valve can't stay open past its runtime just
because the main loop is stuck elsewhere (e.g. blocked reconnecting Wi-Fi,
which is still possible until Piece 3 lands). Every path that ends a run
(manual `stop_watering`, the software deadline check, or catching up after
the hardware alarm already fired) now also cancels any pending alarm before
the run slot is reused, so a stale alarm from a finished run can't later cut
off a different run on the same line.

**Setup:** same as Piece 1 — serial console open, relay wired to a dummy
load you're fine cycling, MQTT access to send `start_watering`/`stop_watering`
commands for the assigned zone/line.

**Test A — regression, normal operation unaffected:**
1. Send `start_watering` with `runtime_seconds: 5` for an assigned line.
2. Confirm relay turns on immediately and turns off at ~5s, with a
   `COMPLETED` status published, same as before this change.
3. Repeat, but send `stop_watering` at ~2s instead of waiting it out.
   Confirm it stops immediately with a `STOPPED` status.
4. Pass: no behavior change to a normal start/stop cycle.

**Test B — cancellation correctness (the one most worth not skipping):**
1. Send `start_watering` with `runtime_seconds: 60`.
2. After ~5s, send `stop_watering` for the same line. Confirm it stops.
3. Keep watching the serial log (and the relay) past the **original**
   60-second mark from step 1.
4. Pass: nothing happens at the ~60s mark — no relay click, no status
   publish, no log line. If the relay clicks again at ~60s, the stale alarm
   from the stopped run wasn't cancelled and just cut off whatever happens
   to be running on that line at that moment — that would be a real bug,
   not a cosmetic one.

**Test C — the actual hardware backstop firing independently (time-sensitive — see note):**
1. Send `start_watering` with `runtime_seconds: 15` for an assigned line.
2. Within a couple seconds, unplug your Wi-Fi router/AP so the board's link
   drops and it gets stuck in `wifi_connect_with_retry()` (this blocking
   behavior is what Piece 3 will remove).
3. Watch the relay itself (not the serial log — MQTT publishes won't reach
   the broker while Wi-Fi is down). Pass: the relay physically turns off at
   ~15s even though the board is mid-reconnect and can't publish anything.
4. Plug the router back in. Once the board reconnects, check the serial log
   for `[actuator] stop zone=... hw_cutoff_fired=1` — confirms the software
   poll caught up afterward and did the deferred status publish/cleanup
   using the same run struct the hardware alarm already flipped off.
5. **Note:** this test proves the backstop works *while the known blocking
   gap still exists*. Once Piece 3 ships and the main loop stops blocking
   for long stretches, reproducing a stall long enough to matter gets much
   harder to do on purpose — which is the point, but it also means this is
   the easiest window to verify the backstop actually does something. Worth
   running before Piece 3, not just after.

**Result:** _(fill in: pass/fail per board, date, who ran it)_
- `pico_w_actuator_node`: not yet run
- `pico_w_combined_node`: not yet run — same provisioning blocker as Piece 1.

---

# Manual Test Log — Command Reliability (Reboot Priority)

Found during a live end-to-end test pass against a provisioned combined node
(2026-08-04): a `reboot` command could be acknowledged (ack published, seen
by Rails) without the device ever actually rebooting, if another command
(e.g. `request_reading`) arrived in the same window. Root cause: reboot was
handled as deferred state (`pending_reboot`) sharing mutable fields with
every other command, promoted to an actual reboot only on a later poll tick
gated on `!pending_command_ack` — and `mqtt_node_disconnect()` unconditionally
reset `pending_reboot` on any reconnect. Confirmed via black-box testing
(Rails/MQTT/DB observation, no serial console) — isolated reboot commands
succeeded twice in a row (uptime/wake_count reset both times); one attempt
immediately followed by a second command did not reboot despite acking fine.

**What changed:** reboot now has its own dedicated state (`reboot_command_id`,
`reboot_ack_pending`, `reboot_armed`) entirely separate from the
`pending_command`/`pending_command_ack` fields every other command shares.
`handle_command_message` ignores any other incoming command while a reboot is
in flight. `mqtt_flush_deferred_actions` handles the reboot ack+arm *first*,
before config apply, other command acks, or publish requests, and returns
immediately once armed. `mqtt_node_disconnect()` no longer touches the reboot
state, so a reboot that's already been accepted survives any reconnect that
races it.

Applies to: `pico_w_sensor_node` and `pico_w_combined_node` (`pico_w_actuator_node`
has no reboot handling to fix). Both compiled clean; no hardware validation
yet — needs a serial console to confirm on real boards.

**Setup:** board provisioned and connected, USB serial attached, MQTT access
to send `reboot` and `request_reading` commands for the assigned node.

**Test A — isolated reboot still works (regression):**
1. Send `reboot` alone, nothing else queued behind it.
2. Confirm the device reboots (serial log shows a fresh boot banner; or
   off-device, the next reading's `uptime_seconds`/`wake_count` reset to a
   small value instead of continuing from before).
3. Pass: behaves the same as before this change — this is a pure reliability
   fix, not a behavior change to the normal path.

**Test B — the actual bug, back-to-back commands:**
1. Send `reboot` for the node.
2. Within ~1-5s (before you'd expect the reboot to have physically happened),
   send `request_reading` for the same node.
3. Confirm the device still reboots — check `uptime_seconds`/`wake_count`
   reset on the next reading after it comes back, same as Test A.
4. Pass: reboot happens regardless of the follow-up command. Before this fix,
   the ack for reboot would still arrive, but the device would keep running
   with uptime climbing uninterrupted — reboot silently never fired.

**Test C — command ignored while reboot in flight:**
1. Send `reboot`, then immediately send `request_reading` (same as Test B).
2. Check whether a `request_reading`-driven fresh reading (`publish_reason:
   "request_reading"`) appears before the reboot. It should not — the
   request_reading should be dropped (device ignores all other commands once
   a reboot is accepted), and the *next* reading you see should be the
   post-reboot one instead.
3. Pass: no stray request_reading reading sneaks in between the reboot ack
   and the actual reboot.

**Result:**
- `pico_w_combined_node`: **PASS** — 2026-08-04, tested black-box (no serial
  console) against the live provisioned board via Rails/MQTT/DB observation.
  - Test A: reboot alone — `wake_count` reset to 1 confirming a fresh boot
    session (uptime continued climbing normally afterward: 21 → 74 on the
    next reading, 53s later matching wall-clock elapsed).
  - Test B: reboot followed by `request_reading` 3s later — device still
    rebooted correctly (fresh reading landed at t+21s post-command,
    `wake_count=1`). Before this fix, the identical sequence left the ack
    succeeding but the device never actually rebooting (uptime climbed
    uninterrupted).
  - Test C: checked full reading history across the test window — only the
    one post-reboot reading exists, no stray request_reading-driven reading
    from the old session snuck in before the reboot took effect.
  - Note: "time to first reading after boot" was consistently ~21s across
    three separate boots (the flash itself, Test A, Test B) — a deterministic
    Wi-Fi+MQTT+subscribe+time-sync startup sequence, not a bug.
- `pico_w_sensor_node`: not yet run — no hardware currently available to flash.

**Addendum (2026-08-04, later same day):** the black-box "PASS" above was
incomplete — a real bug survived it and only surfaced once a serial console
was actually connected. Root cause: `watchdog_reboot(0, 0, delay_ms)` does
**not** halt execution; it schedules a hardware reset `delay_ms` in the
future and the CPU keeps running in the meantime. The code fell through to
the top of the main loop after calling it, and a command already in flight
(e.g. `request_reading` sent a few seconds after `reboot`) could be fully
received and processed — including running an entire extra sensor-publish
cycle — before the scheduled reset actually fired. Confirmed live via serial:
`[main] reboot requested` was followed by a full `reason=request_reading`
publish cycle for all 4 channels, and only then `[main] boot`.

**Fix:** after calling `watchdog_reboot()`, both `pico_w_combined_node` and
`pico_w_sensor_node` now spin in an explicit `while (true) { tight_loop_contents(); }`
instead of returning to the loop, so nothing else can run in that window.
Defense in depth: `reboot_armed` in `pico_w_combined_node`/`pico_w_sensor_node`'s
`mqtt_node.c` is no longer cleared once set (previously cleared the instant
it was promoted to `node->reboot_requested`), so `handle_command_message`
keeps rejecting incoming commands for the rest of the boot's life regardless
of whether the halt loop is ever bypassed by a future change.

**Re-verified live via serial console** (`pico_w_combined_node`, USB serial
attached, `screen`-equivalent capture): reboot + `request_reading` 3s later
now shows `[main] reboot requested"` immediately followed by `[main] boot"` —
zero extra cycles in between, across two consecutive back-to-back tests.
Zero reboot failures across 5 total serial-observed reboots after this fix
(2 back-to-back, 3 isolated). `pico_w_sensor_node` has the identical
`watchdog_reboot()`-without-halt pattern fixed the same way, but has not been
flashed/serial-tested (no second board on hand).

---

# Manual Test Log — Boot-Time Forced Reading

Follow-up to the reboot-priority piece above. Requested directly: after a
reboot (deliberate or watchdog-forced), the operator has no visible
confirmation the board actually came back healthy until the next regularly
scheduled reading — which, outside the active window, could be hours away.

**What changed:** on the first wake/loop pass after boot (tracked with a
`is_first_wake`/`boot_reading_done` flag that persists across a wifi/mqtt
retry `continue`, since no reading has happened yet either way), the firmware
now unconditionally takes one full reading (temp + soil, both channels on the
combined node) and publishes it with `publish_reason: "boot"`, bypassing the
active-window check that would otherwise skip it entirely if the boot happens
outside `VG_DAY_START_HOUR`-`VG_DAY_END_HOUR`. Any `request_reading` pending
at that exact moment is folded into the same cycle rather than triggering a
second, immediately-following read. Every wake/loop pass after the first
behaves exactly as before (active-window gating and interval/request_reading
tagging unchanged).

Applies to: `pico_w_sensor_node` and `pico_w_combined_node`. Both compiled
clean. `pico_w_actuator_node` has no sensor reading logic, not applicable.

**Setup:** board provisioned and connected, USB serial attached if available,
MQTT/Rails access to observe readings.

**Test A — boot reading fires regardless of active window:**
1. Note the current time relative to the zone's active window (day/night
   hours). If currently *inside* the window, this test isn't very
   interesting — prefer running it while outside the window (or temporarily
   narrow the window in the zone's config) so the difference from normal
   behavior is obvious.
2. Reboot the board (via the `reboot` command or a power cycle).
3. Confirm a fresh reading appears shortly after reconnect with
   `publish_reason: "boot"`, even though the current time is outside the
   active window.
4. Pass: the reading appears and is tagged `"boot"`. Before this change,
   outside the active window, no reading would happen at all until the
   window opened or a manual `request_reading` was sent.

**Test B — regression, normal scheduling unaffected after the first reading:**
1. After Test A's boot reading lands, wait for (or trigger) a second reading
   naturally (either the next scheduled interval if inside the window, or by
   sending `request_reading`).
2. Confirm this second reading is tagged normally (`"interval"` or
   `"request_reading"`, not `"boot"`) — the boot tag should only ever appear
   once per boot, on the very first reading.
3. Pass: only the first post-boot reading is tagged `"boot"`; everything
   after reverts to normal tagging and active-window gating.

**Test C — pending request_reading at boot doesn't double-fire:**
1. While the board is still reconnecting after a reboot (before it's taken
   its boot reading), send a `request_reading` command timed to land in that
   window if possible.
2. Confirm only *one* reading appears (tagged `"boot"`), not two back-to-back
   readings.
3. Pass: a request that happens to coincide with the boot reading is folded
   into it, not duplicated.

**Result:**
- `pico_w_combined_node`: **PASS** (core logic) — 2026-08-04, verified live
  via serial console, outside the active window (22:xx local, window is
  6am-8pm).
  - Test A: confirmed repeatedly — `reason=boot` reading fires automatically
    within ~19-21s of every boot, no command needed, regardless of active
    window.
  - Test B: confirmed — every reading after the first reverts to normal
    `"interval"`/`"request_reading"` tagging.
  - Test C: confirmed — no double-fire observed in any test.
  - **Separate finding, not a bug in this piece:** individual channels can
    intermittently fail to publish during the boot reading specifically
    because the retained actuator config (which triggers 4 topic
    subscriptions on arrival) tends to land at the same moment, and the
    lwIP MQTT client's publish buffer is small enough that the two bursts
    collide (`err=mqtt publish buffer full`). Observed across several runs:
    0/4, 1/4, and 4/4 channels dropped from the `"boot"` cycle in different
    attempts, purely timing-dependent — the *dropped* channel's reading
    isn't lost, it just publishes one cycle later under whatever reason
    triggers that next cycle (seen tagged `request_reading` instead of
    `boot` in the DB in two of these runs). This exact error signature
    (`mqtt publish buffer full`) was already present in retained MQTT state
    from earlier in this session, well before any of today's firmware
    changes — it's a pre-existing multi-channel publish reliability gap,
    not something this piece introduced. Worth a dedicated fix later
    (larger buffer, or spacing out the channel publishes / deferring
    actuator config application by a beat), but out of scope here.
- `pico_w_sensor_node`: not yet run — no second board on hand.

---

# Manual Test Log — MQTT "publish buffer full" Root Cause and Fix

Follow-up investigating the `mqtt publish buffer full` errors noted above.
Initial hypothesis (bumping `MQTT_OUTPUT_RINGBUF_SIZE` 1024→4096) was
diagnosed and deployed, but **did not fix the problem** — re-tested live and
channels still failed. Investigated further with a temporary serial-console
probe (added directly to the vendored lwIP source at
`firmware/pico-sdk/lib/lwip/src/apps/mqtt/mqtt.c`'s
`mqtt_output_check_space()`, since removed) that would print whenever the
ring buffer itself was the reason a publish was rejected. It never fired on
a failing publish — proving the ring buffer's byte capacity was never
actually the constraint.

**Real root cause:** `mqtt_publish()`/`mqtt_subscribe()` in lwIP's MQTT
client both call `mqtt_create_request()` *before* ever touching the output
ring buffer — this grabs a slot from a fixed-size pool,
`client->req_list[MQTT_REQ_MAX_IN_FLIGHT]` (lwIP default: 4), and returns
`ERR_MEM` immediately if no slot is free, regardless of ring buffer space. A
slot stays held until the broker's ACK (PUBACK/SUBACK) comes back — a real
network round trip.

The actual culprit consuming those slots: `subscribe_assigned_zone_topics()`
in `mqtt_node.c` looped over every assigned irrigation line/channel and
issued a **separate SUBSCRIBE call to the same zone topic for each one** —
on the combined node, 4 channels commonly assigned to the same zone meant 4
redundant subscribes to the identical topic
(`greenhouse/zones/<zone>/actuator/command`), each holding a request slot
until SUBACK. Combined with a channel-state publish also in flight, this
could exceed the 4-slot pool before any of them were acknowledged — exactly
matching the observed pattern (0-4 of the 4 channel publishes failing,
inconsistently, depending on timing).

**Fix (two parts, both needed for defense in depth):**
1. `subscribe_assigned_zone_topics()` now tracks zone_ids it's already
   subscribed to in this pass and skips duplicates — subscribes once per
   *unique* assigned zone instead of once per assigned line. Applies to
   `pico_w_combined_node` (`VG_MAX_IRRIGATION_LINES=4`) and
   `pico_w_actuator_node` (`VG_MAX_IRRIGATION_LINES=12`, same bug, larger
   potential blast radius). `pico_w_sensor_node` has no actuator zone
   assignments, not applicable.
2. `MQTT_REQ_MAX_IN_FLIGHT` bumped 4→8 in all three `lwipopts.h` for
   headroom against any other concurrent request bursts. `MQTT_OUTPUT_RINGBUF_SIZE`
   (4096, from the earlier investigation) was kept — harmless, cheap
   one-time ~3KB heap cost — even though it wasn't the actual fix.

**Verified live via serial console** (`pico_w_combined_node`): 3 consecutive
reboots, each forcing the exact collision (boot reading's 4-channel publish
burst overlapping with the retained actuator config's subscribe). Every run:
`subscribe zone command topic=...` logged exactly **once** (was 4), zero
`publish failed` lines, all 4 channels present in the DB for both the boot
reading and the following cycle. Previously this same scenario failed
0-4 of 4 channels inconsistently across earlier runs.

**Result:**
- `pico_w_combined_node`: **PASS** — 2026-08-04, 3/3 clean reboots after the
  fix, live via serial console.
- `pico_w_actuator_node`: same redundant-subscribe fix applied, compiles
  clean, not flashed/tested live (no board on hand) — the mechanism is
  identical to the combined node's confirmed fix, but this specific board's
  behavior hasn't been directly observed.
- `pico_w_sensor_node`: `MQTT_REQ_MAX_IN_FLIGHT`/`MQTT_OUTPUT_RINGBUF_SIZE`
  bumped for headroom, no redundant-subscribe bug to fix (no actuator zone
  assignments), not flashed/tested live.

---

# Manual Test Log — NTP-Never-Syncs Fallback (Combined Node)

Found during a "find silent failures" review (2026-08-04): on
`pico_w_combined_node`, the boot-forced reading and every other reading path
were nested entirely inside `if (time_sync_ready())`. If NTP/DNS is down
(upstream outage, bad DNS), the board would never publish a single reading —
not even in response to a manual Request Reading — for as long as the outage
lasted, with nothing anywhere indicating NTP was the cause. `pico_w_sensor_node`
does not have this bug (its reading path already falls through when
unsynced); only the combined node's structure gated everything on time sync.

**What changed:** the boot-forced reading and an explicit manual
`request_reading` now fire regardless of `time_sync_ready()`. Only
interval/active-window scheduling (which genuinely needs wall-clock time to
mean anything) stays gated on it. `run_sensor_cycle()`'s publish path already
had a graceful fallback for this — `time_sync_format_iso8601()` emits a
`1970-01-01T00:MM:SSZ` sentinel (minutes/seconds from device uptime) when
unsynced — it just was never reachable before since nothing upstream of it
could fire without time sync in the first place.

**Companion Rails fix:** `PayloadContracts::NodeState` was parsing that
sentinel literally as `recorded_at`, which would have put a genuinely
1970-dated row in the reading history. Now detects `year <= 1971` and
substitutes server time (`Time.current`, the Pi's own clock is reliably
synced) instead, preserving the actual sensor values. This also retroactively
covers `pico_w_sensor_node`, which has always had this same latent exposure
(it already reads without synced time) — just never hit it because NTP has
been reliable on this network.

**Verified live** by temporarily pointing `VG_DEFAULT_NTP_SERVER` at an
unreachable hostname (`invalid.test.nonexistent`) via a diagnostic build —
genuinely broke DNS resolution/NTP rather than faking a flag — flashed,
confirmed via serial (`[time] still waiting for NTP sync` repeating
throughout) that sync never completed, and confirmed both the boot-forced
reading and a manual request_reading still published successfully (all 4
channels) despite that. Initially caught a real deployment gap this way too:
the Rails contract fix hadn't actually been synced to the Pi yet, so the
first pass showed the literal 1970 `recorded_at` in the DB exactly as
predicted — deployed it, re-tested, confirmed `recorded_at` correctly fell
back to real server time while the device's own raw timestamp stayed the
1970 sentinel. Cleaned up the resulting stray test rows from the DB
afterward. Reverted the diagnostic NTP-server change, rebuilt the real
firmware, reflashed, and confirmed a normal boot (working NTP) still gets a
real timestamp with no regression — plus re-ran a full reboot cycle to
confirm it still composes cleanly with the reboot-priority and MQTT
buffer/request-slot fixes from earlier today (single subscribe, zero publish
failures, zero extra cycles between "reboot requested" and "boot").

**Result:**
- `pico_w_combined_node`: **PASS** — 2026-08-04, verified live via serial
  console with a genuine simulated NTP outage.
- `pico_w_sensor_node`: not applicable (already handled this case), no
  firmware change needed.

---
