class AddMailboxAbuseLimitsToServers < ActiveRecord::Migration[5.2]
  def change
    add_column :servers, :mailbox_domain_recipient_limit_per_minute, :integer
    add_column :servers, :mailbox_recipient_limit_per_message, :integer
    add_column :servers, :mailbox_submission_limit_per_hour, :integer
    add_column :servers, :mailbox_recipient_limit_per_day, :integer
    add_column :servers, :mailbox_hard_fail_limit_per_day, :integer
  end
end
