class AddReputationWarningOutboxToMailboxSubmissionGuards < ActiveRecord::Migration[5.2]
  def up
    add_column :mailbox_submission_guards, :warning_at, :datetime
    add_column :mailbox_submission_guards, :warning_expires_at, :datetime
    add_column :mailbox_submission_guards, :warning_reason, :string
    add_column :mailbox_submission_guards, :warning_notification_enqueued_at, :datetime
    add_index :mailbox_submission_guards,
              [:warning_notification_enqueued_at, :warning_at],
              name: 'index_mailbox_guards_on_warning_notification'

    WebhookEvent.where(event: 'CredentialLocked').find_each do |event|
      WebhookEvent.where(
        webhook_id: event.webhook_id,
        event: 'MailboxReputationWarning'
      ).first_or_create!
    end
  end

  def down
    WebhookEvent.where(event: 'MailboxReputationWarning').delete_all
    remove_index :mailbox_submission_guards, name: 'index_mailbox_guards_on_warning_notification'
    remove_column :mailbox_submission_guards, :warning_notification_enqueued_at
    remove_column :mailbox_submission_guards, :warning_reason
    remove_column :mailbox_submission_guards, :warning_expires_at
    remove_column :mailbox_submission_guards, :warning_at
  end
end
