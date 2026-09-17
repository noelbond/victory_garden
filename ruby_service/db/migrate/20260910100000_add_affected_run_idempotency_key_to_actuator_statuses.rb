class AddAffectedRunIdempotencyKeyToActuatorStatuses < ActiveRecord::Migration[8.0]
  def change
    add_column :actuator_statuses, :affected_run_idempotency_key, :string
  end
end
