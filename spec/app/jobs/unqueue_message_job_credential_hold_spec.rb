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
      :sender_ip => nil
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
end
