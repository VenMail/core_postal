require 'rails_helper'

RSpec.describe 'API authenticator source' do
  subject(:source) { File.read(Rails.root.join('api/authenticator.rb')) }

  it 'loads the master key from configuration and resolves trusted provenance' do
    expect(source).to include('Postal.config.general.master_api_key')
    expect(source).to include('Postal::ClientIpProvenance.resolve')
    expect(source).not_to match(/key\s*==\s*['"][^'"]{20,}['"]/)
  end

  it 'checks a trusted actor or falls back to the transport peer before credential lookup' do
    expect(source).to include('provenance.trusted_gateway ? provenance.external_actor_ip : provenance.transport_peer_ip')
    expect(source).to include('GlobalSuppression.ip_banned?(blocked_ip)')
    expect(source).to include("error 'IPBanned'")
  end
end
