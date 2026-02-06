class CreateGlobalSuppressions < ActiveRecord::Migration[5.2]
  def change
    create_table :global_suppressions do |t|
      t.string :ip_address, null: false, index: { unique: true }
      t.text :reason, null: false
      t.datetime :keep_until # nil for permanent bans
      t.timestamps
    end
    
    add_index :global_suppressions, [:ip_address, :keep_until]
  end
end
