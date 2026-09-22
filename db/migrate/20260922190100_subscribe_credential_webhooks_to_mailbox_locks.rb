class SubscribeCredentialWebhooksToMailboxLocks < ActiveRecord::Migration[5.2]
  def up
    WebhookEvent.where(event: 'CredentialLocked').find_each do |event|
      WebhookEvent.where(webhook_id: event.webhook_id, event: 'MailboxLocked').first_or_create!
    end
  end

  def down
    WebhookEvent.where(event: 'MailboxLocked').delete_all
  end
end
