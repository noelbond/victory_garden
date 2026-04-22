class AddUniqueIndexToActuatorStatuses < ActiveRecord::Migration[8.0]
  def change
    add_index :actuator_statuses,
              [:idempotency_key, :state],
              unique: true,
              where: "idempotency_key IS NOT NULL",
              name: "index_actuator_statuses_on_idempotency_key_and_state_unique"
  end
end
