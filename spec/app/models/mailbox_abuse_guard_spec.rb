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
        10
      end

      def self.bounce_policy_for(server:, domain:)
        { :minimum_sample_size => 10, :threshold_percent => 8.0 }
      end

      def self.begin_mailbox_lock!(server:, mailbox:, reason:, mailbox_active:)
      end

      def self.enqueue_mailbox_lock_notification!(event)
      end
    end
    stub_const('MailboxSubmissionGuard', submission_guard)
    allow(MailboxSubmissionGuard).to receive(:begin_mailbox_lock!).and_return(double('lock event'))
    allow(MailboxSubmissionGuard).to receive(:enqueue_mailbox_lock_notification!).and_return(true)
  end

  it 'locks a shared mailbox when its correlated 24-hour failure rate exceeds eight percent' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 10, 'failures' => 1 }])
    allow(mail_user).to receive(:deactivate).with('sender@venia.cloud').and_return(true)
    expect(MailboxSubmissionGuard).to receive(:begin_mailbox_lock!).with(
      server: server,
      mailbox: 'sender@venia.cloud',
      reason: include('10.0% bounce rate'),
      mailbox_active: true
    ).once.and_return(double('lock event'))

    expect(described_class.lock_after_hard_fail!(message)).to be true
  end

  it 'does not lock from a percentage until the shared mailbox sample is large enough' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 9, 'failures' => 9 }])
    expect(mail_user).not_to receive(:deactivate)
    expect(MailboxSubmissionGuard).not_to receive(:begin_mailbox_lock!)

    expect(described_class.lock_after_hard_fail!(message)).to be false
  end

  it 'retains the absolute hard-failure lock as a second safety boundary' do
    allow(database).to receive(:escape).with('sender@venia.cloud').and_return("'sender@venia.cloud'")
    allow(database).to receive(:query).and_return([{ 'total' => 10, 'failures' => 10 }])
    allow(mail_user).to receive(:deactivate).with('sender@venia.cloud').and_return(true)
    expect(MailboxSubmissionGuard).to receive(:begin_mailbox_lock!).with(
      server: server,
      mailbox: 'sender@venia.cloud',
      reason: include('10 outbound delivery failures'),
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
