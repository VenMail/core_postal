class AddVenmailOrganizationBindingToServers < ActiveRecord::Migration[4.2]
  def change
    # This is the immutable Venmail/Laravel organization primary key, not the
    # Postal parent organization. It lets a caller prove which upstream tenant
    # owns a Postal server before any destructive operation is permitted.
    add_column :servers, :venmail_organization_id, :bigint
    add_index :servers, :venmail_organization_id, :unique => true,
              :name => 'index_servers_on_venmail_organization_id'
  end
end
