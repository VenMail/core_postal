require 'spec_helper'

RSpec.describe 'mailbox lock notification outbox' do
  let(:guard_source) do
    File.read(File.expand_path('../../app/models/mailbox_submission_guard.rb', __dir__))
  end
  let(:monitor_source) do
    File.read(File.expand_path('../../app/jobs/reputation_monitor_job.rb', __dir__))
  end

  it 'records the lock before deactivation and marks notification only after webhook creation' do
    expect(guard_source).to include('begin_mailbox_lock!')
    expect(guard_source).to include('lock_notification_enqueued_at')
    expect(guard_source).to match(/WebhookRequest\.trigger.*?update!\(lock_notification_enqueued_at:/m)
  end

  it 'retries pending mailbox lock notifications from the recurring reputation job' do
    expect(monitor_source).to include('MailboxSubmissionGuard.retry_pending_mailbox_warnings!')
    expect(monitor_source).to include('MailboxSubmissionGuard.retry_pending_mailbox_locks!')
  end

  it 'registers the warning webhook event' do
    event_source = File.read(File.expand_path('../../app/models/webhook_event.rb', __dir__))

    expect(event_source).to include("'MailboxReputationWarning'")
  end

  it 'subscribes existing credential-alert webhooks to mailbox warnings' do
    migration_source = File.read(File.expand_path('../../db/migrate/20261013113000_add_reputation_warning_outbox_to_mailbox_submission_guards.rb', __dir__))

    expect(migration_source).to include("event: 'CredentialLocked'")
    expect(migration_source).to include("event: 'MailboxReputationWarning'")
  end
end
