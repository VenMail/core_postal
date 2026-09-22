require 'rails_helper'

RSpec.describe UnqueueMessageJob do
  let(:job) do
    described_class.new('test-job', {}).tap do |instance|
      allow(instance).to receive(:log)
    end
  end

  it 'stores metadata and emits one event for compromise-pattern holds' do
    credential = create(:credential)
    expect(WebhookRequest).to receive(:trigger).with(
      credential.server,
      'CredentialLocked',
      hash_including(
        :credential => hash_including(:uuid => credential.uuid),
        :reason => 'Compromise suspected'
      )
    ).once

    job.send(:hold_credential, credential, 'Compromise suspected')

    credential.reload
    expect(credential.hold).to be(true)
    expect(credential.hold_at).not_to be_nil
    expect(credential.hold_reason).to eq('Compromise suspected')
  end

  it 'emits one event for repeated high-confidence spam' do
    credential = create(:credential)
    message_db = double('message_db')
    server = credential.server
    allow(server).to receive(:message_db).and_return(message_db)
    allow(message_db).to receive(:select).and_return(3)
    message = double(
      'message',
      :spam_score => 20.0,
      :credential_id => credential.id,
      :domain_id => nil,
      :credential => credential,
      :verified_sender_ip => nil
    )
    queued_message = double('queued_message', :message => message, :server => server)
    expect(WebhookRequest).to receive(:trigger).with(
      server,
      'CredentialLocked',
      hash_including(:credential => hash_including(:uuid => credential.uuid))
    ).once

    job.send(:lock_credential_or_ip_for_high_spam, queued_message, '[test]')

    credential.reload
    expect(credential.hold).to be(true)
    expect(credential.hold_at).not_to be_nil
    expect(credential.hold_reason).to include('High-confidence outbound spam')
  end

  it 'holds a queued message from a banned submitter without deleting the evidence' do
    message = double('message', :verified_sender_ip => '204.10.162.167')
    queued_message = double('queued_message', :message => message)
    allow(GlobalSuppression).to receive(:ip_banned?).with('204.10.162.167').and_return(true)
    expect(message).to receive(:create_delivery).with('Held', hash_including(:details => include('banned')))
    expect(message).not_to receive(:delete)
    expect(queued_message).to receive(:destroy)

    expect(job.send(:hold_if_sender_ip_banned, queued_message, '[test]')).to be true
  end

  it 'does not enforce an IP ban based only on a legacy Received header' do
    message = double('legacy message', :verified_sender_ip => nil, :sender_ip => '204.10.162.167')
    queued_message = double('queued_message', :message => message)
    expect(GlobalSuppression).not_to receive(:ip_banned?)
    expect(queued_message).not_to receive(:destroy)

    expect(job.send(:hold_if_sender_ip_banned, queued_message, '[test]')).to be false
  end
end
