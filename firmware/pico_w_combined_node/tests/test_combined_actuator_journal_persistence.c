#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "combined_actuator_journal_persistence.h"
#include "simulated_flash_backend.h"

static vg_actuator_start_journal_record_t record(unsigned n) {
    vg_actuator_start_journal_record_t r = { .accepted=true, .version=VG_ACTUATOR_START_JOURNAL_RECORD_VERSION,
        .irrigation_line=1u, .issued_at_epoch_seconds=1700000000 + (int64_t)n };
    snprintf(r.idempotency_key,sizeof(r.idempotency_key),"key-%u",n); strcpy(r.zone_id,"zone"); strcpy(r.node_id,"node"); return r;
}
static void init(vg_simulated_flash_backend_t *flash, vg_actuator_start_journal_storage_t *storage,
                 vg_combined_actuator_journal_runtime_state_t *runtime) {
    vg_simulated_flash_backend_init(flash); const vg_actuator_start_journal_storage_backend_t b=vg_simulated_flash_backend_interface(flash);
    assert(vg_actuator_start_journal_storage_open(storage,&b)==VG_ACTUATOR_START_JOURNAL_STORAGE_BLANK);
    assert(vg_actuator_start_journal_storage_initialize(storage)==VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    vg_combined_actuator_journal_runtime_state_from_storage(runtime,storage,false);
}
static vg_actuator_start_journal_candidate_t candidate(vg_actuator_start_journal_storage_t *s, unsigned n) {
    vg_actuator_start_journal_candidate_t c; vg_actuator_start_journal_record_t r=record(n);
    assert(vg_actuator_start_journal_prepare(&s->logical_journal,r.idempotency_key,r.zone_id,r.node_id,r.irrigation_line,r.issued_at_epoch_seconds,&c)==VG_ACTUATOR_START_JOURNAL_NEW); return c;
}
int main(void) {
    vg_simulated_flash_backend_t flash; vg_actuator_start_journal_storage_t storage; vg_combined_actuator_journal_runtime_state_t runtime; bool read_failed=false; uint64_t seq=0;
    init(&flash,&storage,&runtime); vg_actuator_start_journal_candidate_t c=candidate(&storage,1u);
    assert(vg_combined_actuator_journal_persistence_append_prepared(&storage,&runtime,&read_failed,false,&c,&seq)==VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_OK);
    assert(seq==1u && storage.record_count==1u);
    flash.trace_count=0u;
    assert(vg_combined_actuator_journal_classify_start(&runtime,&storage.logical_journal,"key-1","zone","node",1u,1700000001)==VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
    assert(flash.trace_count==0u); // Same-boot duplicate is read-only.
    const vg_actuator_start_journal_storage_backend_t backend=vg_simulated_flash_backend_interface(&flash);
    vg_actuator_start_journal_storage_t rebooted;
    assert(vg_actuator_start_journal_storage_open(&rebooted,&backend)==VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_combined_actuator_journal_runtime_state_t rebooted_runtime;
    vg_combined_actuator_journal_runtime_state_from_storage(&rebooted_runtime,&rebooted,false);
    assert(vg_combined_actuator_journal_classify_start(&rebooted_runtime,&rebooted.logical_journal,"key-1","zone","node",1u,1700000001)==VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
    c=candidate(&storage,2u); flash.trace_count=0u;
    assert(vg_combined_actuator_journal_persistence_append_prepared(&storage,&runtime,&read_failed,true,&c,&seq)==VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_BUSY);
    assert(flash.trace_count==0u);
    vg_simulated_flash_backend_set_fault(&flash,VG_SIMULATED_FLASH_FAULT_BEFORE_PROGRAM,1u,0u);
    assert(vg_combined_actuator_journal_persistence_append_prepared(&storage,&runtime,&read_failed,false,&c,&seq)==VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE);
    assert(storage.record_count==1u);
    vg_simulated_flash_backend_clear_fault(&flash);
    c=candidate(&storage,3u);
    c.slot=VG_ACTUATOR_START_JOURNAL_FLASH_LOGICAL_CAPACITY; // force RAM commit failure after valid flash write
    assert(vg_combined_actuator_journal_persistence_append_prepared(&storage,&runtime,&read_failed,false,&c,&seq)==VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_COMMIT_FAILED);
    assert(vg_combined_actuator_journal_classify_start(&runtime,&storage.logical_journal,"key-3","zone","node",1u,1700000003)==VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);
    c=candidate(&storage,4u);
    vg_simulated_flash_backend_set_fault(&flash,VG_SIMULATED_FLASH_FAULT_AFTER_PROGRAM,1u,0u);
    assert(vg_combined_actuator_journal_persistence_append_prepared(&storage,&runtime,&read_failed,false,&c,&seq)==VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_UNAVAILABLE);
    vg_simulated_flash_backend_clear_fault(&flash);
    assert(vg_actuator_start_journal_storage_open(&rebooted,&backend)==VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_combined_actuator_journal_runtime_state_from_storage(&rebooted_runtime,&rebooted,false);
    assert(vg_combined_actuator_journal_classify_start(&rebooted_runtime,&rebooted.logical_journal,"key-4","zone","node",1u,1700000004)==VG_COMBINED_ACTUATOR_JOURNAL_ADMISSION_DUPLICATE);

    // Full all-expired history compacts to empty without resetting high-water.
    init(&flash,&storage,&runtime); read_failed=false;
    for (unsigned n=1u; n<=VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT; ++n) {
        vg_actuator_start_journal_record_t r=record(n); uint64_t s=0u;
        assert(vg_actuator_start_journal_storage_append_verified(&storage,&r,&s)==VG_ACTUATOR_START_JOURNAL_STORAGE_OK);
    }
    const vg_actuator_start_journal_storage_backend_t b2=vg_simulated_flash_backend_interface(&flash);
    assert(vg_actuator_start_journal_storage_open(&storage,&b2)==VG_ACTUATOR_START_JOURNAL_STORAGE_HEALTHY_WITH_RECORDS);
    vg_combined_actuator_journal_runtime_state_from_storage(&runtime,&storage,false);
    vg_actuator_start_journal_flash_accepted_record_t snapshot[VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT];
    assert(vg_combined_actuator_journal_persistence_reclaim_full(&storage,&runtime,&read_failed,false,1700000100,true,snapshot,VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT)==VG_COMBINED_ACTUATOR_JOURNAL_RECLAIM_READY);
    assert(storage.record_count==0u && storage.current_high_water==VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT);
    c=candidate(&storage,99u);
    assert(vg_combined_actuator_journal_persistence_append_prepared(&storage,&runtime,&read_failed,false,&c,&seq)==VG_COMBINED_ACTUATOR_JOURNAL_PERSISTENCE_OK);
    assert(seq==VG_ACTUATOR_START_JOURNAL_STORAGE_RECORD_PAGE_COUNT+1u);
    return 0;
}
