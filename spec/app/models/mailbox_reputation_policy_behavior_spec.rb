require 'spec_helper'
require 'active_record'
require 'active_support/core_ext/numeric/time'

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end unless defined?(ApplicationRecord)

module Postal
  def self.config
  end
end unless defined?(Postal)

load ENV.fetch('MAILBOX_SUBMISSION_GUARD_SOURCE', File.expand_path('../../../app/models/mailbox_submission_guard.rb', __dir__))

RSpec.describe MailboxSubmissionGuard do
  let(:server) do
    double(
      'server',
      :id => 61,
      :mailbox_hard_fail_limit_per_day => nil,
      :mailbox_domain_recipient_limit_per_minute => nil,
      :mailbox_recipient_limit_per_message => nil,
      :mailbox_submission_limit_per_hour => nil,
      :mailbox_recipient_limit_per_day => nil
    )
  end
  let(:general) do
    double(
      'general config',
      :shared_free_domains => ['venia.cloud'],
      :shared_free_mailbox_hard_fail_limit_per_day => 5,
      :reputation_warning_threshold_percent => 2.0,
      :reputation_hold_threshold_percent => 4.0,
      :reputation_warning_min_sample_size => 25,
      :reputation_hold_min_sample_size => 50,
      :shared_free_mailbox_warning_min_sample_size => 10,
      :shared_free_mailbox_hold_min_sample_size => 25,
      :reputation_warning_min_failures => 1,
      :reputation_hold_min_failures => 2,
      :reputation_absolute_failure_limit => 5,
      :reputation_warning_lifetime_hours => 24,
      :shared_free_domain_recipient_limit_per_minute => 60,
      :shared_free_mailbox_recipient_limit_per_message => 3,
      :shared_free_mailbox_submission_limit_per_hour => 5,
      :shared_free_mailbox_recipient_limit_per_day => 10,
      :reputation_throttled_recipient_limit_per_message => 1,
      :reputation_throttled_submission_limit_per_hour => 2,
      :reputation_throttled_recipient_limit_per_day => 5
    )
  end

  before do
    allow(Postal).to receive(:config).and_return(double('postal config', :general => general))
  end

  it 'uses smaller warning evidence for a protected shared domain without weakening the hold evidence floor' do
    expect(described_class.reputation_policy_for(server: server, domain: 'venia.cloud')).to eq(
      :warning => { :threshold_percent => 2.0, :minimum_sample_size => 10, :minimum_failures => 1 },
      :hold => { :threshold_percent => 4.0, :minimum_sample_size => 25, :minimum_failures => 2 },
      :absolute_failure_limit => 5,
      :warning_lifetime => 24.hours
    )
  end

  it 'uses the general evidence floors for a protected customer-domain mailbox' do
    allow(server).to receive(:mailbox_hard_fail_limit_per_day).and_return(10)

    expect(described_class.reputation_policy_for(server: server, domain: 'customer.example')).to eq(
      :warning => { :threshold_percent => 2.0, :minimum_sample_size => 25, :minimum_failures => 1 },
      :hold => { :threshold_percent => 4.0, :minimum_sample_size => 50, :minimum_failures => 2 },
      :absolute_failure_limit => 5,
      :warning_lifetime => 24.hours
    )
  end

  it 'falls back below the SES review boundary when threshold configuration is unsafe' do
    allow(general).to receive(:reputation_warning_threshold_percent).and_return(0)
    allow(general).to receive(:reputation_hold_threshold_percent).and_return(5)

    policy = described_class.reputation_policy_for(server: server, domain: 'venia.cloud')

    expect(policy[:warning][:threshold_percent]).to eq(2.0)
    expect(policy[:hold][:threshold_percent]).to eq(4.0)
  end

  it 'uses the already locked mailbox guard to cap an active warning at one recipient per message' do
    now = Time.utc(2026, 10, 13, 12, 0, 0)
    domain_guard = double('domain guard', :minute_recipients => 0)
    mailbox_guard = double(
      'mailbox guard',
      :warning_expires_at => now + 1.hour,
      :hour_submissions => 0,
      :day_recipients => 0
    )

    allow(described_class).to receive(:transaction).with(requires_new: true).and_yield
    expect(described_class).to receive(:locked_guards).once.and_return([domain_guard, mailbox_guard])
    allow(described_class).to receive(:reset_expired_windows!)

    expect do
      described_class.reserve!(
        server: server,
        domain: 'venia.cloud',
        mailbox: 'sender@venia.cloud',
        recipients: 2,
        now: now
      )
    end.to raise_error(MailboxSubmissionGuard::LimitExceeded) { |error| expect(error.reason).to eq(:recipient_limit_per_message) }
  end

  it 'clears an expired warning and restores ordinary submission limits' do
    now = Time.utc(2026, 10, 13, 12, 0, 0)
    domain_guard = double('domain guard', :minute_recipients => 0)
    mailbox_guard = double(
      'mailbox guard',
      :warning_expires_at => now,
      :hour_submissions => 0,
      :day_recipients => 0,
      :minute_recipients => 0
    )

    allow(described_class).to receive(:transaction).with(requires_new: true).and_yield
    expect(described_class).to receive(:locked_guards).once.and_return([domain_guard, mailbox_guard])
    allow(described_class).to receive(:reset_expired_windows!)
    expect(mailbox_guard).to receive(:update!).with(
      warning_at: nil,
      warning_expires_at: nil,
      warning_reason: nil,
      warning_notification_enqueued_at: nil
    ).ordered
    expect(domain_guard).to receive(:update!).with(minute_recipients: 3).ordered
    expect(mailbox_guard).to receive(:update!).with(
      minute_recipients: 3,
      hour_submissions: 1,
      day_recipients: 3
    ).ordered

    expect do
      described_class.reserve!(
        server: server,
        domain: 'venia.cloud',
        mailbox: 'sender@venia.cloud',
        recipients: 3,
        now: now
      )
    end.not_to raise_error
  end
end
