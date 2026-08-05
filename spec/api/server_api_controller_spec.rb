require 'rails_helper'
require 'json'

describe 'Server API upstream binding' do
  let(:master_key) { 'configured-master-key' }
  let(:parent_organization) { create(:organization) }

  before do
    Postal.config.general.master_api_key = master_key
    allow_any_instance_of(Server).to receive(:provision_database).and_return(false)
  end

  def server_api_post(action, params)
    post "/api/v1/server/#{action}",
         :params => params.to_json,
         :headers => {
           'CONTENT_TYPE' => 'application/json',
           'X-Master-Key' => master_key,
           # Exercise the default configuration, which intentionally has no
           # optional general.whitelist setting. Docker-network requests are
           # the supported internal master-API path.
           'REMOTE_ADDR' => '172.19.0.2'
         }
    JSON.parse(response.body)
  end

  def create_params(upstream_id, name = 'Example Mail')
    {
      :organization_id => parent_organization.id,
      :venmail_organization_id => upstream_id,
      :name => name,
      :mode => 'Live'
    }
  end

  it 'creates and reuses a server by immutable upstream organization identity' do
    first = server_api_post('create', create_params(8101))
    second = server_api_post('create', create_params(8101, 'renamed by caller'))

    expect(first.fetch('status')).to eq('success')
    expect(second.fetch('status')).to eq('success')
    expect(second.fetch('data').fetch('server_id')).to eq(first.fetch('data').fetch('server_id'))
    expect(Server.where(:venmail_organization_id => 8101).count).to eq(1)
  end

  it 'rejects a changed callback URL on an idempotent create retry' do
    first = server_api_post('create', create_params(8107))
    expect(first.fetch('status')).to eq('success')

    replay = server_api_post('create', create_params(8107).merge(
      :webhook => 'https://attacker.example.test/api/v1/mails/org/8107'
    ))

    expect(replay.fetch('status')).to eq('error')
    expect(HTTPEndpoint.where(:server_id => first.fetch('data').fetch('server_id'), :name => 'DefaultEndpoint').pluck(:url))
      .not_to include('https://attacker.example.test/api/v1/mails/org/8107')
  end

  it 'does not remove a server when the supplied upstream organization does not own it' do
    server = create(:server, :organization => parent_organization, :venmail_organization_id => 8102)

    response_payload = server_api_post('remove', :server_id => server.id, :venmail_organization_id => 8103)

    expect(response_payload.fetch('status')).to eq('error')
    expect(Server.where(:id => server.id)).to exist
  end

  it 'reports an explicitly addressed missing server as idempotently absent' do
    response_payload = server_api_post('identity', :server_id => 999_991, :venmail_organization_id => 8104)

    expect(response_payload.fetch('status')).to eq('success')
    expect(response_payload.fetch('data')).to include(
      'server_id' => 999_991,
      'venmail_organization_id' => 8104,
      'exists' => false
    )
  end

  it 'requires a concrete Postal server ID for identity and remove operations' do
    identity = server_api_post('identity', :venmail_organization_id => 8108)
    remove = server_api_post('remove', :venmail_organization_id => 8108)

    expect(identity.fetch('status')).to eq('error')
    expect(remove.fetch('status')).to eq('error')
  end

  it 'only backfills an unbound legacy server when both parent and immutable-name evidence match' do
    server = create(:server,
                    :organization => parent_organization,
                    :name => 'venmail-org-8105-legacy',
                    :venmail_organization_id => nil)

    response_payload = server_api_post('bind',
                                       :server_id => server.id,
                                       :organization_id => parent_organization.id,
                                       :venmail_organization_id => 8105)

    expect(response_payload.fetch('status')).to eq('success')
    expect(server.reload.venmail_organization_id).to eq(8105)

    conflicting = create(:server,
                         :organization => parent_organization,
                         :name => 'unproven-legacy-server',
                         :venmail_organization_id => nil)
    rejected = server_api_post('bind',
                               :server_id => conflicting.id,
                               :organization_id => parent_organization.id,
                               :venmail_organization_id => 8106)

    expect(rejected.fetch('status')).to eq('error')
    expect(conflicting.reload.venmail_organization_id).to be_nil
  end
end
