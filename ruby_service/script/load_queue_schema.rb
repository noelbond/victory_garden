#!/usr/bin/env ruby

require_relative "../config/environment"
require "active_record/tasks/database_tasks"

queue_db_config = ActiveRecord::Base.configurations.configs_for(
  env_name: ENV.fetch("RAILS_ENV", Rails.env),
  name: "queue"
)

abort "Queue database configuration not found" unless queue_db_config

schema_path = Rails.root.join("db/queue_schema.rb")
abort "Queue schema not found at #{schema_path}" unless schema_path.exist?

ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(queue_db_config) do
  ActiveRecord::Tasks::DatabaseTasks.load_schema(queue_db_config, :ruby, schema_path.to_s)
end
