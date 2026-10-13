class AddLockOutboxToMailboxSubmissionGuards < ActiveRecord::Migration[5.2]
  def change
    add_column :mailbox_submission_guards, :locked_at, :datetime
    add_column :mailbox_submission_guards, :lock_reason, :string
    add_column :mailbox_submission_guards, :lock_notification_enqueued_at, :datetime
    add_index :mailbox_submission_guards,
              [:lock_notification_enqueued_at, :locked_at],
              name: 'index_mailbox_guards_on_lock_notification'
  end
end
