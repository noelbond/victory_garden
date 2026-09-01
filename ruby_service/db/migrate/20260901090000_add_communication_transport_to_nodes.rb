class AddCommunicationTransportToNodes < ActiveRecord::Migration[8.0]
  def change
    add_column :nodes, :communication_transport, :string, null: false, default: "wifi"
  end
end
