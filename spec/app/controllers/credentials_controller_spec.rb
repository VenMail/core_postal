require 'rails_helper'

RSpec.describe CredentialsController, type: :controller do
  let(:server) { create(:server) }
  let(:credential) { create(:credential, :server => server) }
  let(:user) { server.organization.owner }

  before do
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
  end

  it 'adds manual hold metadata and emits one CredentialLocked event' do
    expect(WebhookRequest).to receive(:trigger).with(
      server,
      'CredentialLocked',
      hash_including(
        :credential => hash_including(:uuid => credential.uuid),
        :reason => 'Manual hold by administrator'
      )
    ).once

    patch :update, :params => {
      :org_permalink => server.organization.permalink,
      :server_id => server.permalink,
      :id => credential.uuid,
      :credential => { :hold => '1', :name => credential.name }
    }

    expect(response).to have_http_status(:redirect)
    credential.reload
    expect(credential.hold).to be(true)
    expect(credential.hold_at).not_to be_nil
    expect(credential.hold_reason).to eq('Manual hold by administrator')
  end

  it 'does not emit a credential hold event for a name-only update' do
    expect(WebhookRequest).not_to receive(:trigger)

    patch :update, :params => {
      :org_permalink => server.organization.permalink,
      :server_id => server.permalink,
      :id => credential.uuid,
      :credential => { :name => 'Renamed credential' }
    }

    expect(response).to have_http_status(:redirect)
    expect(credential.reload.name).to eq('Renamed credential')
  end
end
