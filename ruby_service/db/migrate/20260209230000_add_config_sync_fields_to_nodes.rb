class AddConfigSyncFieldsToNodes < ActiveRecord::Migration[8.0]
  def change
    change_table :nodes do |t|
      t.jsonb :desired_config, null: false, default: {}
      t.jsonb :applied_config, null: false, default: {}
      t.string :config_version
      t.string :config_status
      t.datetime :config_published_at
      t.datetime :config_acknowledged_at
      t.text :config_error
    end
  end
end
