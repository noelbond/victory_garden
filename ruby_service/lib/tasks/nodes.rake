namespace :nodes do
  desc "Backfill friendly names for nodes assigned to a zone before the name column existed"
  task backfill_names: :environment do
    zones = Zone.includes(:nodes).where(id: Node.assigned.select(:zone_id))
    zones.find_each do |zone|
      Node.sync_default_names_for_zone!(zone)
    end
    puts "Synced friendly names for #{zones.count} zone(s)."
  end
end
