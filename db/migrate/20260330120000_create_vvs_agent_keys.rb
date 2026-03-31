class CreateVvsAgentKeys < ActiveRecord::Migration[5.2]
  def change
    create_table :vvs_agent_keys do |t|
      t.integer :server_id
      t.string :agent_name, null: false
      t.string :domain, null: false
      t.binary :private_key, null: false, limit: 64
      t.binary :public_key, null: false, limit: 32
      t.integer :key_version, null: false, default: 1
      t.string :status, null: false, default: 'active'
      t.timestamps
    end
    add_index :vvs_agent_keys, [:agent_name, :domain, :key_version], unique: true, name: 'idx_vvs_agent_unique'
    add_index :vvs_agent_keys, [:agent_name, :domain, :status], name: 'idx_vvs_agent_lookup'
  end
end
