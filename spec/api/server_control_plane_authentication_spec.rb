require 'rails_helper'
require 'json'

describe 'Server control-plane authentication' do
  let(:authenticated_server) { create(:server) }
  let(:credential) { create(:credential, :api, :server => authenticated_server) }
  let(:banned_ip) { '203.0.113.44' }
  let(:master_key) { 'configured-master-key' }

  def api_post(path, params = {}, headers = {})
    post path,
         :params => params.to_json,
         :headers => {
           'CONTENT_TYPE' => 'application/json',
           'X-Server-API-Key' => credential.key,
           'X-Master-Key' => master_key,
           'REMOTE_ADDR' => banned_ip
         }.merge(headers)
    JSON.parse(response.body)
  end

  before do
    Postal.config.general.master_api_key = master_key
    Postal.config.general.whitelist = [banned_ip]
    GlobalSuppression.ban_ip(banned_ip, :reason => 'Control-plane authentication contract')
  end

  it 'allows a valid server credential to retrieve DKIM provisioning material from a suppressed IP' do
    domain = create(:domain, :owner => authenticated_server)

    response_payload = api_post('/api/v1/domains/get', :id => domain.id)

    expect(response_payload.fetch('status')).to eq('success')
    expect(response_payload.fetch('data')).to include(
      'id' => domain.id,
      'dkim_record' => domain.dkim_record,
      'dkim_material_status' => 'ready'
    )
    expect(OpenSSL::PKey::RSA.new(domain.dkim_private_key).n.num_bits).to eq(Domain::DKIM_KEY_BITS)
  end

  context 'with a provisioned message database' do
    let(:authenticated_server) { GLOBAL_SERVER }

    it 'allows a valid server credential to use every server management API from a suppressed IP' do
      domain = create(:domain, :owner => authenticated_server)

      domain_response = api_post('/api/v1/domains/get', :id => domain.id)
      credentials_response = api_post('/api/v1/credentials/list')
      routes_response = api_post('/api/v1/routes/list')
      message_response = api_post('/api/v1/messages/message', :id => 9_999_999)

      expect(domain_response.fetch('status')).to eq('success')
      expect(credentials_response.fetch('status')).to eq('success')
      expect(routes_response.fetch('status')).to eq('success')
      # The API's error envelope for a missing message is intentionally different
      # from the authentication error envelope.  The exact error code proves this
      # management endpoint reached its action instead of being rejected at the
      # global-suppression authenticator boundary.
      expect(message_response.fetch('status')).to eq('error')
      expect(message_response.fetch('data').fetch('code')).to eq('MessageNotFound')
      expect(message_response.to_json).not_to include('IPBanned')
    end
  end

  it 'does not bypass suppression for an invalid control-plane API key' do
    response_payload = api_post('/api/v1/domains/list', {}, 'X-Server-API-Key' => 'invalid-key')

    expect(response_payload.fetch('status')).to eq('error')
    expect(response_payload.fetch('data').fetch('code')).to eq('IPBanned')
  end

  it 'does not bypass suppression without the configured master credential' do
    response_payload = api_post('/api/v1/domains/list', {}, 'X-Master-Key' => 'wrong')

    expect(response_payload.fetch('status')).to eq('error')
    expect(response_payload.fetch('data').fetch('code')).to eq('IPBanned')
  end

  it 'does not bypass suppression from an untrusted source' do
    Postal.config.general.whitelist = []

    response_payload = api_post('/api/v1/domains/list')

    expect(response_payload.fetch('status')).to eq('error')
    expect(response_payload.fetch('data').fetch('code')).to eq('IPBanned')
  end

  it 'keeps authenticated mail submission blocked for a suppressed IP' do
    response_payload = api_post('/api/v1/send/message')

    expect(response_payload.fetch('status')).to eq('error')
    expect(response_payload.fetch('data').fetch('code')).to eq('IPBanned')
  end

  context 'from a globally suppressed public IPv6 address' do
    let(:banned_ip) { '2606:4700:4700::1111' }

    it 'allows a valid credential-scoped Core management domains request' do
      domain = create(:domain, :owner => authenticated_server)

      response_payload = api_post('/api/v1/domains/get', :id => domain.id)

      expect(GlobalSuppression.ip_banned?(banned_ip)).to be(true)
      expect(response_payload.fetch('status')).to eq('success')
      expect(response_payload.fetch('data')).to include('id' => domain.id)
    end

    it 'keeps mail submission rejected as IPBanned from the same IPv6 address' do
      response_payload = api_post('/api/v1/send/message')

      expect(GlobalSuppression.ip_banned?(banned_ip)).to be(true)
      expect(response_payload.fetch('status')).to eq('error')
      expect(response_payload.fetch('data').fetch('code')).to eq('IPBanned')
    end
  end
end
