require 'spec_helper'
require 'active_support/core_ext/numeric/time'
require ENV.fetch('MAILBOX_ABUSE_GUARD_SOURCE', File.expand_path('../../../app/models/mailbox_abuse_guard', __dir__))

RSpec.describe MailboxAbuseGuard do
  let(:server) { double('server') }
  let(:domain) { double('domain', :name => 'venia.cloud') }
  let(:mail_user) { double('mail_user', :active? => true) }
  let(:database) { double('message database', :mail_user => mail_user, :database_name => 'postal-server-test') }
  let(:message) do
    double(
      'message',
      :authenticated_mailbox => 'sender@venia.cloud',
      :database => database,
      :domain => domain,
      :server => server
    )
  end

  before do
    submission_guard = Class.new do
      def self.hard_fail_limit_for(server:, domain:)
        5
      end

      def self.reputation_policy_for(server:, domain:)
        {
          :warning => { :minimum_sample_size => 25, :minimum_failures => 1, :threshold_percent => 2.0 },
          :hold => { :minimum_sample_size => 50, :minimum_failures => 2, :threshold_percent => 4.0 },
          :absolute_failure_limit => 5,
          :warning_lifetime => 24.hours
        }
      end

      def self.begin_mailbox_lock!(server:, mailbox:, reason:, mailbox_active:)
      end

      def self.enqueue_mailbox_lock_notification!(event)
      end

      def self.begin_mailbox_warning!(server:, mailbox:, reason:, now:, expires_at:)
      end

      def self.enqueue_mailbox_warning_notification!(event)
      end
    end
    stub_const('MailboxSubmissionGuard', submission_guard)
    allow(MailboxSubmissionGuard).to receive(:begin_mailbox_lock!).and_return(double('lock event'))
    allow(MailboxSubmissionGuard).to receive(:enqueue_mailbox_lock_notification!).and_return(true)
    allow(MailboxSubmissionGuard).to receive(:begin_mailbox_warning!).and_return(double('warning event'))
    allow(MailboxSubmissionGuard).to receive(:enqueue_mailbox_warning_notification!).and_return(true)
  end

  it 'warns without deactivating when the warning boundary has enough evidence' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 25, 'failures' => 1 }])
    expect(mail_user).not_to receive(:deactivate)
    expect(MailboxSubmissionGuard).not_to receive(:begin_mailbox_lock!)
    expect(MailboxSubmissionGuard).to receive(:begin_mailbox_warning!).with(
      server: server,
      mailbox: 'sender@venia.cloud',
      reason: include('4.0% failure rate'),
      now: kind_of(Time),
      expires_at: kind_of(Time)
    ).once.and_return(double('warning event'))
    expect(MailboxSubmissionGuard).to receive(:enqueue_mailbox_warning_notification!).once

    expect(described_class.lock_after_hard_fail!(message)).to be false
  end

  it 'does nothing until the warning sample is large enough' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 24, 'failures' => 1 }])
    expect(mail_user).not_to receive(:deactivate)
    expect(MailboxSubmissionGuard).not_to receive(:begin_mailbox_lock!)
    expect(MailboxSubmissionGuard).not_to receive(:begin_mailbox_warning!)

    expect(described_class.lock_after_hard_fail!(message)).to be false
  end

  it 'locks at four percent when the hold boundary has enough evidence' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 50, 'failures' => 2 }])
    allow(mail_user).to receive(:deactivate).with('sender@venia.cloud').and_return(true)
    expect(MailboxSubmissionGuard).to receive(:begin_mailbox_lock!).with(
      server: server,
      mailbox: 'sender@venia.cloud',
      reason: include('4.0% failure rate'),
      mailbox_active: true
    ).once.and_return(double('lock event'))

    expect(described_class.lock_after_hard_fail!(message)).to be true
  end

  it 'locks at the absolute five-failure safety boundary regardless of sample size' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 5, 'failures' => 5 }])
    allow(mail_user).to receive(:deactivate).with('sender@venia.cloud').and_return(true)
    expect(MailboxSubmissionGuard).to receive(:begin_mailbox_lock!).with(
      server: server,
      mailbox: 'sender@venia.cloud',
      reason: include('5 outbound delivery failures'),
      mailbox_active: true
    ).once.and_return(double('lock event'))

    expect(described_class.lock_after_hard_fail!(message)).to be true
  end

  it 'counts only terminal delivery outcomes in the rolling window, once per message' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query) do |sql|
      expect(sql).to include("deliveries.status IN ('Sent', 'HardFail', 'Bounced')")
      expect(sql).to include('deliveries.timestamp >=')
      expect(sql).to include('GROUP BY deliveries.message_id')
      expect(sql).not_to include('messages.timestamp >=')
      [{ 'total' => 9, 'failures' => 1 }]
    end

    expect(described_class.lock_after_delivery_failure!(message)).to be false
  end
end
