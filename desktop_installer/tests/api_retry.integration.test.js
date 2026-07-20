import test from "node:test"
import assert from "node:assert/strict"

import {
  classifyPiConnectivityError,
  retryAsyncOperation,
} from "../src/lib/installer_core.js"

test("retryAsyncOperation retries transient Pi errors and then succeeds", async () => {
  const attempts = []
  const waits = []
  let calls = 0

  const result = await retryAsyncOperation({
    attempts: 4,
    baseDelayMs: 100,
    maxDelayMs: 1000,
    jitterRatio: 0,
    sleepFn: async (delayMs) => {
      waits.push(delayMs)
    },
    randomFn: () => 0.5,
    operation: async (attempt) => {
      attempts.push(attempt)
      calls += 1
      if (calls < 3) {
        throw new Error("could not connect to the Pi over HTTP: 192.168.4.33:3000: Connection refused")
      }
      return { ok: true }
    },
  })

  assert.deepEqual(result, { ok: true })
  assert.deepEqual(attempts, [1, 2, 3])
  assert.deepEqual(waits, [100, 200])
})

test("retryAsyncOperation does not retry non-transient Pi API failures", async () => {
  let calls = 0

  await assert.rejects(
    retryAsyncOperation({
      attempts: 4,
      baseDelayMs: 100,
      maxDelayMs: 1000,
      jitterRatio: 0,
      sleepFn: async () => {},
      operation: async () => {
        calls += 1
        throw new Error("could not decode JSON response from http://192.168.4.33:3000/setup_api/bootstrap: invalid type")
      },
    }),
    /could not decode JSON response/i,
  )

  assert.equal(calls, 1)
})

test("classifyPiConnectivityError marks local offline status as transient", () => {
  const classified = classifyPiConnectivityError(new Error("arbitrary network error"), { online: false })
  assert.equal(classified.category, "local-offline")
  assert.equal(classified.transient, true)
})
