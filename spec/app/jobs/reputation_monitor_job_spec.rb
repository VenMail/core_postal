require 'rails_helper'

RSpec.describe ReputationMonitorJob do
  it 'stores bounded metadata and emits one model-level event when suspending a credential' do
    credential = create(:credential)
    job = described_class.new('test-job', {})
    allow(job).to receive(:consider_server_suspension_optimized)
    expect(WebhookRequest).to receive(:trigger).with(
      credential.server,
      'CredentialLocked',
      hash_including(
        :credential => hash_including(:uuid => credential.uuid),
        :reason => a_string_including('Smart spam detection')
      )
    ).once

    job.send(
      :suspend_credential_optimized,
      credential,
      credential.server,
      { :count => 12 },
      8.5,
      { 'spam_probability' => 0.91 }
    )

    credential.reload
    expect(credential.hold).to be(true)
    expect(credential.hold_at).not_to be_nil
    expect(credential.hold_reason).to include('Smart spam detection')
    expect(credential.hold_reason.length).to be <= 255
  end
end
