class CreateMailboxSubmissionGuards < ActiveRecord::Migration[5.2]
  def change
    create_table :mailbox_submission_guards do |t|
      t.integer :server_id, null: false
      t.string :guard_key, null: false
      t.datetime :minute_started_at
      t.integer :minute_recipients, null: false, default: 0
      t.datetime :hour_started_at
      t.integer :hour_submissions, null: false, default: 0
      t.datetime :day_started_at
      t.integer :day_recipients, null: false, default: 0
      t.timestamps
    end

    add_index :mailbox_submission_guards, [:server_id, :guard_key], unique: true,
              name: 'index_mailbox_submission_guards_on_server_and_key'
  end
end
