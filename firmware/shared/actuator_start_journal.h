#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "actuator_command_freshness.h"

// These storage sizes match the current actuator command and topology fields.
// They include the terminating NUL byte.
#define VG_ACTUATOR_START_JOURNAL_MAX_IDEMPOTENCY_KEY_LEN 96u
#define VG_ACTUATOR_START_JOURNAL_MAX_ZONE_ID_LEN 32u
#define VG_ACTUATOR_START_JOURNAL_MAX_NODE_ID_LEN 32u
#define VG_ACTUATOR_START_JOURNAL_RECORD_VERSION 2u
#define VG_ACTUATOR_START_JOURNAL_RETENTION_MARGIN_SECONDS 10

// An accepted record means this START may have reached relay energization. It
// deliberately says nothing about whether watering completed or even began.
typedef struct {
    bool accepted;
    uint8_t version;
    char idempotency_key[VG_ACTUATOR_START_JOURNAL_MAX_IDEMPOTENCY_KEY_LEN];
    char zone_id[VG_ACTUATOR_START_JOURNAL_MAX_ZONE_ID_LEN];
    char node_id[VG_ACTUATOR_START_JOURNAL_MAX_NODE_ID_LEN];
    uint8_t irrigation_line;
    int64_t issued_at_epoch_seconds;
} vg_actuator_start_journal_record_t;

typedef struct {
    vg_actuator_start_journal_record_t *records;
    size_t capacity;
} vg_actuator_start_journal_t;

typedef enum {
    // The key is unseen and candidate contains a record that must be persisted
    // and verified before commit_verified() or any side effect.
    VG_ACTUATOR_START_JOURNAL_NEW = 0,
    // The same key is already accepted with the identical target binding.
    VG_ACTUATOR_START_JOURNAL_DUPLICATE,
    // The same key is already accepted for another target binding.
    VG_ACTUATOR_START_JOURNAL_KEY_CONFLICT,
    // The key is unseen and no unused record exists. Eviction is forbidden
    // until command freshness defines a safe retention window.
    VG_ACTUATOR_START_JOURNAL_FULL,
    VG_ACTUATOR_START_JOURNAL_INVALID_ARGUMENT,
    // Loaded caller-owned records include an invalid accepted entry. Treating
    // that entry as free could replay a command, so callers must fail closed.
    VG_ACTUATOR_START_JOURNAL_INVALID_RECORD,
} vg_actuator_start_journal_result_t;

typedef struct {
    bool prepared;
    size_t slot;
    vg_actuator_start_journal_record_t record;
} vg_actuator_start_journal_candidate_t;

// Binds the journal to caller-owned records without clearing or changing them.
// Callers load durable records before initialization and explicitly prune only
// after trusted UTC proves records are outside the replay-risk window.
bool vg_actuator_start_journal_init(
    vg_actuator_start_journal_t *journal,
    vg_actuator_start_journal_record_t *records,
    size_t capacity
);

// Checks whether a loaded or candidate record is a valid accepted START
// identity. Checksums and flash serialization remain adapter responsibilities.
bool vg_actuator_start_journal_record_is_valid(const vg_actuator_start_journal_record_t *record);

// Produces a NEW candidate without changing journal storage. A NEW result is
// not permission to energize an output. The caller must durably persist and
// verify candidate.record, then call commit_verified() successfully first.
vg_actuator_start_journal_result_t vg_actuator_start_journal_prepare(
    const vg_actuator_start_journal_t *journal,
    const char *idempotency_key,
    const char *zone_id,
    const char *node_id,
    uint8_t irrigation_line,
    int64_t issued_at_epoch_seconds,
    vg_actuator_start_journal_candidate_t *candidate_out
);

// Updates the in-memory journal only after the caller has durably persisted
// and verified the exact prepared candidate. A true result is the module's
// explicit side-effect admission point; false means fail closed.
bool vg_actuator_start_journal_commit_verified(
    vg_actuator_start_journal_t *journal,
    const vg_actuator_start_journal_candidate_t *candidate
);

// A record is prunable only when trusted UTC is strictly later than its
// immutable issued_at plus the freshness window and retention margin.
bool vg_actuator_start_journal_record_is_safe_to_prune(
    const vg_actuator_start_journal_record_t *record,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
);

// Explicitly frees only records proven safe to forget. It performs no flash
// I/O and leaves invalid or non-expired records unchanged so callers fail
// closed. Returns the number of records removed.
size_t vg_actuator_start_journal_prune(
    vg_actuator_start_journal_t *journal,
    int64_t trusted_now_epoch_seconds,
    bool trusted_time
);
