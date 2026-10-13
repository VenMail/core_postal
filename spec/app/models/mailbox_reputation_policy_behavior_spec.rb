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
  let(:server) { double('server', :mailbox_hard_fail_limit_per_day => nil) }
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
      :reputation_warning_lifetime_hours => 24
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
    allow(server).to receive(:mailbox_hard_fail_limit_per_day).and_return(5)

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
end
