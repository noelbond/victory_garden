class AddDetailsToCropProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :crop_profiles, :climate_preference, :string
    add_column :crop_profiles, :time_to_harvest_days, :integer
  end
end
