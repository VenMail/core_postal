class CreateAuthAttempts < ActiveRecord::Migration[5.2]
  def change
    create_table :auth_attempts do |t|
      t.string :scope_key, null: false
      t.integer :count, default: 0
      t.datetime :window_started_at
      t.datetime :blocked_until
      t.timestamps
    end
    add_index :auth_attempts, :scope_key, unique: true
  end
end
