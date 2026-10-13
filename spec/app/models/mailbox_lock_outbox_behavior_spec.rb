require 'spec_helper'
require 'active_record'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/time'

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end unless defined?(ApplicationRecord)

load ENV.fetch('MAILBOX_SUBMISSION_GUARD_SOURCE', File.expand_path('../../../app/models/mailbox_submission_guard.rb', __dir__))

RSpec.describe MailboxSubmissionGuard, type: :model do
  before do
    webhook_request = Class.new do
      def self.trigger(*)
      end
    end
    stub_const('WebhookRequest', webhook_request)
  end

  describe '.begin_mailbox_lock!' do
    it 'persists a pending lock transition before notification delivery' do
      server = double('server', :id => 61)
      guard = double(
        'guard',
        :locked_at => nil,
        :lock_notification_enqueued_at => nil,
        :lock_reason => nil
      )
      relation = double('relation')

      allow(described_class).to receive(:ensure_guard_exists!).with(61, 'mailbox:sender@venia.cloud')
      allow(described_class).to receive(:transaction).with(requires_new: true).and_yield
      allow(described_class).to receive(:where).with(server_id: 61, guard_key: 'mailbox:sender@venia.cloud').and_return(relation)
      allow(relation).to receive(:lock).and_return(relation)
      allow(relation).to receive(:first!).and_return(guard)
      expect(guard).to receive(:update!).with(
        locked_at: kind_of(Time),
        lock_reason: 'rate exceeded',
        lock_notification_enqueued_at: nil
      )

      expect(described_class.begin_mailbox_lock!(
        server: server,
        mailbox: 'Sender@Venia.Cloud',
        reason: 'rate exceeded',
        mailbox_active: true
      )).to equal(guard)
    end
  end

  describe '.begin_mailbox_warning!' do
    it 'persists a pending warning cycle before notification delivery' do
      server = double('server', :id => 61)
      now = Time.utc(2026, 10, 13, 12, 0, 0)
      expires_at = now + 24.hours
      guard = double(
        'guard',
        :warning_at => nil,
        :warning_expires_at => nil,
        :warning_notification_enqueued_at => nil,
        :warning_reason => nil
      )
      relation = double('relation')

      allow(described_class).to receive(:ensure_guard_exists!).with(61, 'mailbox:sender@venia.cloud')
      allow(described_class).to receive(:transaction).with(requires_new: true).and_yield
      allow(described_class).to receive(:where).with(server_id: 61, guard_key: 'mailbox:sender@venia.cloud').and_return(relation)
      allow(relation).to receive(:lock).and_return(relation)
      allow(relation).to receive(:first!).and_return(guard)
      expect(guard).to receive(:update!).with(
        warning_at: now,
        warning_expires_at: expires_at,
        warning_reason: 'rate elevated',
        warning_notification_enqueued_at: nil
      )

      expect(described_class.begin_mailbox_warning!(
        server: server,
        mailbox: 'Sender@Venia.Cloud',
        reason: 'rate elevated',
        now: now,
        expires_at: expires_at
      )).to equal(guard)
    end
  end

  describe '.enqueue_mailbox_lock_notification!' do
    let(:server) { double('server') }
    let(:locked_at) { Time.utc(2026, 10, 13, 9, 0, 0) }
    let(:guard) do
      double(
        'guard',
        :guard_key => 'mailbox:sender@venia.cloud',
        :server => server,
        :lock_reason => 'rate exceeded',
        :locked_at => locked_at,
        :lock_notification_enqueued_at => nil
      )
    end

    before do
      allow(guard).to receive(:with_lock).and_yield
    end

    it 'marks the outbox item only after the webhook request is created' do
      expect(WebhookRequest).to receive(:trigger).with(
        server,
        'MailboxLocked',
        hash_including(:mailbox => 'sender@venia.cloud', :locked_at => locked_at.iso8601)
      ).ordered
      expect(guard).to receive(:update!).with(lock_notification_enqueued_at: kind_of(Time)).ordered

      expect(described_class.enqueue_mailbox_lock_notification!(guard)).to be true
    end

    it 'leaves the outbox item pending when webhook creation fails' do
      allow(WebhookRequest).to receive(:trigger).and_raise('database unavailable')
      expect(guard).not_to receive(:update!)

      expect do
        described_class.enqueue_mailbox_lock_notification!(guard)
      end.to raise_error(RuntimeError, 'database unavailable')
    end
  end

  describe '.enqueue_mailbox_warning_notification!' do
    let(:server) { double('server') }
    let(:warning_at) { Time.utc(2026, 10, 13, 9, 0, 0) }
    let(:warning_expires_at) { warning_at + 24.hours }
    let(:guard) do
      double(
        'guard',
        :guard_key => 'mailbox:sender@venia.cloud',
        :server => server,
        :warning_reason => 'rate elevated',
        :warning_at => warning_at,
        :warning_expires_at => warning_expires_at,
        :warning_notification_enqueued_at => nil
      )
    end

    before do
      allow(guard).to receive(:with_lock).and_yield
    end

    it 'marks the warning outbox only after the webhook request is created' do
      expect(WebhookRequest).to receive(:trigger).with(
        server,
        'MailboxReputationWarning',
        {
          :mailbox => 'sender@venia.cloud',
          :reason => 'rate elevated',
          :warning_at => warning_at.iso8601,
          :warning_expires_at => warning_expires_at.iso8601
        }
      ).ordered
      expect(guard).to receive(:update!).with(warning_notification_enqueued_at: kind_of(Time)).ordered

      expect(described_class.enqueue_mailbox_warning_notification!(guard)).to be true
    end

    it 'leaves the warning outbox pending when webhook creation fails' do
      allow(WebhookRequest).to receive(:trigger).and_raise('database unavailable')
      expect(guard).not_to receive(:update!)

      expect do
        described_class.enqueue_mailbox_warning_notification!(guard)
      end.to raise_error(RuntimeError, 'database unavailable')
    end
  end
end
