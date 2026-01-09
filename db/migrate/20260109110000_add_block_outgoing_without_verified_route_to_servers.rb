class AddBlockOutgoingWithoutVerifiedRouteToServers < ActiveRecord::Migration[4.2]
  def change
    add_column :servers, :block_outgoing_without_verified_route, :boolean, :default => false
    add_index :servers, :block_outgoing_without_verified_route
  end
end
