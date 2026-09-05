require 'rails_helper'
require 'json'

describe 'Credentials API hold events' do
  let(:master_key) { 'configured-master-key' }
  let(:server) { create(:server) }
  let(:api_credential) { create(:credential, :api, :server => server) }

  before do
    Postal.config.general.master_api_key = master_key
  end

  def credentials_api_post(action, params)
    post "/api/v1/credentials/#{action}",
         :params => params.to_json,
         :headers => {
           'CONTENT_TYPE' => 'application/json',
           'X-Server-API-Key' => api_credential.key,
           'X-Master-Key' => master_key,
           'REMOTE_ADDR' => '172.19.0.2'
         }
    JSON.parse(response.body)
  end

  it 'records revoke metadata and emits exactly one model-level event' do
    webhook = create(:webhook, :server => server)
    create(:webhook_event, :webhook => webhook, :event => 'CredentialLocked')
    credential = create(:credential, :server => server)

    expect do
      response_payload = credentials_api_post('revoke', :uuid => credential.uuid)
      expect(response_payload.fetch('status')).to eq('success')
    end.to change { WebhookRequest.where(:event => 'CredentialLocked').count }.by(1)

    credential.reload
    expect(credential.hold).to eq(true)
    expect(credential.hold_at).not_to be_nil
    expect(credential.hold_reason).to eq('Revoked')
  end

  it 'does not overwrite hold metadata or emit again on a repeated revoke' do
    webhook = create(:webhook, :server => server)
    create(:webhook_event, :webhook => webhook, :event => 'CredentialLocked')
    original_hold_at = 1.day.ago.change(:usec => 0)
    original_reason = 'Automated abuse hold'
    credential = create(
      :credential,
      :server => server,
      :hold => true,
      :hold_at => original_hold_at,
      :hold_reason => original_reason
    )

    expect do
      response_payload = credentials_api_post('revoke', :uuid => credential.uuid)
      expect(response_payload.fetch('status')).to eq('success')
    end.not_to change { WebhookRequest.where(:event => 'CredentialLocked').count }

    credential.reload
    expect(credential.hold_at).to eq(original_hold_at)
    expect(credential.hold_reason).to eq(original_reason)
  end
end
