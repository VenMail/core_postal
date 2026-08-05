require 'rails_helper'

RSpec.describe 'API authenticator source' do
  subject(:source) { File.read(Rails.root.join('api/authenticator.rb')) }

  it 'loads the master key from configuration and shares the trust predicate' do
    expect(source).to include('Postal.config.general.master_api_key')
    expect(source).to include('Postal::ApiRequestTrust.trusted?')
    expect(source).not_to match(/key\s*==\s*['"][^'"]{20,}['"]/)
  end

  it 'requires a valid server credential and trusted control plane before bypassing an IP ban' do
    expect(source).to include('credential && trusted_control_plane')
    expect(source).to include('GlobalSuppression.ip_banned?(request.ip)')
    expect(source).to include("error 'IPBanned'")
  end
end
