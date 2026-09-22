require 'rails_helper'

RSpec.describe MailboxSubmissionGuard, type: :model do
  let(:server) { create(:server) }
  let(:now) { Time.utc(2026, 9, 22, 12, 0, 0) }

  before do
    allow(Postal.config.general).to receive(:shared_free_domains).and_return(['venia.cloud'])
    allow(Postal.config.general).to receive(:shared_free_domain_recipient_limit_per_minute).and_return(60)
    allow(Postal.config.general).to receive(:shared_free_mailbox_recipient_limit_per_message).and_return(3)
    allow(Postal.config.general).to receive(:shared_free_mailbox_submission_limit_per_hour).and_return(5)
    allow(Postal.config.general).to receive(:shared_free_mailbox_recipient_limit_per_day).and_return(10)
  end

  it 'rejects a shared-domain submission above the per-message recipient limit without consuming capacity' do
    expect do
      described_class.reserve!(server: server, domain: 'venia.cloud', mailbox: 'free@venia.cloud', recipients: 4, now: now)
    end.to raise_error(MailboxSubmissionGuard::LimitExceeded) { |error| expect(error.reason).to eq(:recipient_limit_per_message) }

    expect(MailboxSubmissionGuard.count).to eq(0)
  end

  it 'enforces the shared domain recipient limit across mailboxes in the same minute' do
    allow(Postal.config.general).to receive(:shared_free_mailbox_recipient_limit_per_message).and_return(100)
    described_class.reserve!(server: server, domain: 'venia.cloud', mailbox: 'first@venia.cloud', recipients: 60, now: now)

    expect do
      described_class.reserve!(server: server, domain: 'venia.cloud', mailbox: 'second@venia.cloud', recipients: 1, now: now + 10.seconds)
    end.to raise_error(MailboxSubmissionGuard::LimitExceeded) { |error| expect(error.reason).to eq(:domain_recipient_limit_per_minute) }
  end

  it 'does not apply shared free-domain limits to a customer domain' do
    expect do
      described_class.reserve!(server: server, domain: 'customer.example', mailbox: 'sender@customer.example', recipients: 100, now: now)
    end.not_to raise_error

    expect(MailboxSubmissionGuard.count).to eq(0)
  end
end
