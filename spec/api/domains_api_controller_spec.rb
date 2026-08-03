require 'rails_helper'
require 'json'

RSpec.describe 'Domains API', :type => :request do
  let(:authenticated_server) { create(:server) }
  let(:credential) { create(:credential, :api, :server => authenticated_server) }

  def domains_api_request(action, params = {}, api_key = credential.key)
    post "/api/v1/domains/#{action}",
         :params => params.to_json,
         :headers => {
           'CONTENT_TYPE' => 'application/json',
           'X-Server-API-Key' => api_key
         }
    JSON.parse(response.body)
  end

  it 'returns the same public DKIM contract for get, find, list, create, verify, and scoped repair' do
    domain = create(:domain, :owner => authenticated_server, :name => 'contract.example', :verified_at => nil)

    get_response = domains_api_request('get', :id => domain.id)
    find_response = domains_api_request('find_by_name', :name => domain.name)
    list_response = domains_api_request('list')
    create_response = domains_api_request('domain', :name => 'created-contract.example')
    verify_response = domains_api_request('verify', :id => domain.id, :force => true)
    repair_response = domains_api_request('update_single_dkim', :id => domain.id, :regenerate => true)

    responses = [
      get_response.fetch('data'),
      find_response.fetch('data'),
      list_response.fetch('data').find { |entry| entry.fetch('id') == domain.id },
      create_response.fetch('data'),
      verify_response.fetch('data'),
      repair_response.fetch('data')
    ]

    responses.each do |payload|
      expect(payload).to include('id', 'name', 'dkim_identifier', 'dkim_record', 'dkim_record_name')
      expect(payload).not_to have_key('dkim_private_key')
      expect(payload).not_to have_key('server_id')
    end
  end

  it 'only exports the private key when the owning server explicitly opts in' do
    domain = create(:domain, :owner => authenticated_server)
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization)
    other_server = create(:server)
    other_credential = create(:credential, :api, :server => other_server)

    default_response = domains_api_request('get', :id => domain.id)
    opted_in_response = domains_api_request('get', :id => domain.id, :include_private_key => true)
    organization_response = domains_api_request('get', :id => organization_domain.id, :include_private_key => true)
    foreign_response = domains_api_request('get', { :id => domain.id, :include_private_key => true }, other_credential.key)

    expect(default_response.fetch('data')).not_to have_key('dkim_private_key')
    expect(opted_in_response.fetch('data').fetch('dkim_private_key')).to eq(domain.dkim_private_key)
    expect(organization_response.fetch('status')).to eq('success')
    expect(organization_response.fetch('data')).not_to have_key('dkim_private_key')
    expect(foreign_response.fetch('status')).not_to eq('success')
  end

  it 'does not let another server retrieve a domain by ID or name' do
    other_domain = create(:domain, :owner => create(:server), :name => 'other-server.example')

    by_id = domains_api_request('get', :id => other_domain.id)
    by_name = domains_api_request('find_by_name', :name => other_domain.name)

    expect(by_id.fetch('status')).not_to eq('success')
    expect(by_name.fetch('status')).not_to eq('success')
  end

  it 'prefers a directly owned domain over a shared organization domain with the same name' do
    name = 'shared-name.example'
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization, :name => name)
    server_domain = create(:domain, :owner => authenticated_server, :name => name)

    response_payload = domains_api_request('find_by_name', :name => name, :include_private_key => true)

    expect(response_payload.fetch('status')).to eq('success')
    expect(response_payload.fetch('data').fetch('id')).to eq(server_domain.id)
    expect(response_payload.fetch('data').fetch('dkim_private_key')).to eq(server_domain.dkim_private_key)
    expect(response_payload.fetch('data').fetch('id')).not_to eq(organization_domain.id)
  end

  it 'does not let another server verify, delete, or regenerate a domain' do
    other_domain = create(:domain, :owner => create(:server), :verified_at => nil)
    original_private_key = other_domain.dkim_private_key

    verify_response = domains_api_request('verify', :id => other_domain.id, :force => true)
    update_response = domains_api_request('update_single_dkim', :id => other_domain.id, :regenerate => true)
    destroy_response = domains_api_request('destroy', :id => other_domain.id)

    expect(verify_response.fetch('status')).not_to eq('success')
    expect(update_response.fetch('status')).not_to eq('success')
    expect(destroy_response.fetch('status')).not_to eq('success')
    expect(other_domain.reload.dkim_private_key).to eq(original_private_key)
    expect(Domain.where(:id => other_domain.id)).to exist
  end

  it 'does not let a server credential delete a shared organization domain' do
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization)

    response_payload = domains_api_request('destroy', :id => organization_domain.id)

    expect(response_payload.fetch('status')).not_to eq('success')
    expect(Domain.where(:id => organization_domain.id)).to exist
  end

  it 'creates and explicitly regenerates 2048-bit DKIM keys' do
    create_response = domains_api_request('domain', :name => 'new-key-size.example')
    created_domain = Domain.find(create_response.fetch('data').fetch('id'))
    existing_domain = create(:domain, :owner => authenticated_server)

    regenerate_response = domains_api_request('update_single_dkim', :id => existing_domain.id, :regenerate => true)

    expect(OpenSSL::PKey::RSA.new(created_domain.dkim_private_key).n.num_bits).to be >= 2048
    expect(OpenSSL::PKey::RSA.new(existing_domain.reload.dkim_private_key).n.num_bits).to be >= 2048
    expect(regenerate_response.fetch('data').fetch('dkim_record')).to start_with('v=DKIM1;')
  end

  it 'rejects undersized BYODKIM material without replacing an existing key' do
    domain = create(:domain, :owner => authenticated_server)
    original_private_key = domain.dkim_private_key
    weak_private_key = OpenSSL::PKey::RSA.new(1024).to_s

    create_response = domains_api_request('domain', :name => 'weak-byodkim.example', :dkim_private_key => weak_private_key)
    update_response = domains_api_request('update_single_dkim', :id => domain.id, :dkim_private_key => weak_private_key)

    expect(create_response.fetch('status')).not_to eq('success')
    expect(update_response.fetch('status')).not_to eq('success')
    expect(Domain.where(:name => 'weak-byodkim.example')).to be_empty
    expect(domain.reload.dkim_private_key).to eq(original_private_key)
  end

  it 'rejects a DKIM placeholder selector before it is persisted' do
    response_payload = domains_api_request('domain',
                                           :name => 'placeholder-selector.example',
                                           :dkim_identifier_string => '%dkim_data%')

    expect(response_payload.fetch('status')).not_to eq('success')
    expect(Domain.where(:name => 'placeholder-selector.example')).to be_empty
  end

  it 'keeps legacy 1024-bit material readable until an explicit scoped repair' do
    domain = create(:domain, :owner => authenticated_server)
    legacy_private_key = OpenSSL::PKey::RSA.new(1024).to_s
    domain.update_column(:dkim_private_key, legacy_private_key)

    response_payload = domains_api_request('get', :id => domain.id)

    expect(response_payload.fetch('status')).to eq('success')
    expect(response_payload.fetch('data').fetch('dkim_record')).to start_with('v=DKIM1;')
    expect(domain.reload.dkim_private_key).to eq(legacy_private_key)
  end

  it 'does not emit a legacy DKIM placeholder as a selector or record name' do
    domain = create(:domain, :owner => authenticated_server)
    domain.update_column(:dkim_identifier_string, '%dkim_data%')

    response_payload = domains_api_request('get', :id => domain.id)
    payload = response_payload.fetch('data')

    expect(payload.fetch('dkim_identifier')).to be_nil
    expect(payload.fetch('dkim_record_name')).to be_nil
    expect(payload.fetch('dkim_record')).to be_nil
    expect(payload.to_s).not_to include('%dkim_data%')
  end

  it 'does not use the legacy organization-wide mutation endpoint to rotate DKIM material' do
    own_domain = create(:domain, :owner => authenticated_server)
    sibling_server = create(:server, :organization => authenticated_server.organization, :name => 'Sibling server')
    sibling_domain = create(:domain, :owner => sibling_server)
    own_original_key = own_domain.dkim_private_key
    sibling_original_key = sibling_domain.dkim_private_key

    response_payload = domains_api_request('update_dkim',
                                            :organization_id => authenticated_server.organization.id,
                                            :regenerate_keys => true)

    expect(response_payload.fetch('status')).not_to eq('success')
    expect(own_domain.reload.dkim_private_key).to eq(own_original_key)
    expect(sibling_domain.reload.dkim_private_key).to eq(sibling_original_key)
  end
end
