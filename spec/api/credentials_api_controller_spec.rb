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

  it 'releases a held credential and emits CredentialUnlocked exactly once' do
    webhook = create(:webhook, :server => server)
    create(:webhook_event, :webhook => webhook, :event => 'CredentialUnlocked')
    credential = create(
      :credential,
      :server => server,
      :hold => true,
      :hold_at => 1.hour.ago,
      :hold_reason => 'Automated compromise protection'
    )

    expect do
      response_payload = credentials_api_post('release', :uuid => credential.uuid)
      expect(response_payload.fetch('status')).to eq('success')
      expect(response_payload.fetch('data')).to include(
        'id' => credential.id,
        'uuid' => credential.uuid,
        'hold' => false,
        'idempotent' => false
      )
    end.to change { WebhookRequest.where(:event => 'CredentialUnlocked').count }.by(1)

    credential.reload
    expect(credential.hold).to eq(false)
    expect(credential.hold_at).to be_nil
    expect(credential.hold_reason).to be_nil

    expect do
      response_payload = credentials_api_post('release', :uuid => credential.uuid)
      expect(response_payload.fetch('status')).to eq('success')
      expect(response_payload.fetch('data')).to include(
        'uuid' => credential.uuid,
        'hold' => false,
        'idempotent' => true
      )
    end.not_to change { WebhookRequest.where(:event => 'CredentialUnlocked').count }
  end

  it 'cannot release a credential belonging to another server' do
    other_server = create(:server)
    credential = create(:credential, :server => other_server, :hold => true)

    response_payload = credentials_api_post('release', :uuid => credential.uuid)

    expect(response_payload.fetch('status')).to eq('error')
    expect(response_payload.fetch('data').fetch('code')).to eq('NotFound')
    expect(credential.reload.hold).to eq(true)
  end
end
