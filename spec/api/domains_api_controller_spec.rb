require 'rails_helper'
require 'json'

describe 'Domains API' do
  let(:authenticated_server) { create(:server) }
  let(:credential) { create(:credential, :api, :server => authenticated_server) }

  def domains_api_get(action, params = {})
    post "/api/v1/domains/#{action}",
        :params => params.to_json,
        :headers => {
          'CONTENT_TYPE' => 'application/json',
          'X-Server-API-Key' => credential.key
        }
    JSON.parse(response.body)
  end

  it 'returns an explicit public DKIM payload and never a private key by default' do
    domain = create(:domain, :owner => authenticated_server, :dkim_identifier_string => 'A1B2C3')
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    response_payload = domains_api_get('get', :id => domain.id)
    expect(response_payload.fetch('status')).to eq('success')
    data = response_payload.fetch('data')
    expect(data).to include(
      'dkim_selector' => 'venmail-A1B2C3',
      'dkim_record_name' => 'venmail-A1B2C3._domainkey'
    )
    expect(data.fetch('dkim')).to include(
      'selector' => 'venmail-A1B2C3',
      'record_name' => 'venmail-A1B2C3._domainkey',
      'record' => domain.dkim_record,
      'status' => 'ready'
    )
    expect(data).not_to have_key('dkim_private_key')
  end

  it 'exposes explicit root-token and DKIM verification states without inferring either from generic verification' do
    domain = create(:domain, :owner => authenticated_server)
    domain.update_columns(:verified_at => Time.now, :verification_token_verified_at => nil, :dkim_status => 'Invalid')

    initial_response = domains_api_get('get', :id => domain.id)
    initial_data = initial_response.fetch('data')
    expect(initial_data).to include(
      'verification_token_verified_at' => nil,
      'verification_token_status' => 'Pending',
      'dkim_verified' => false
    )

    verified_at = Time.now
    domain.update_columns(
      :verification_token_verified_at => verified_at,
      :verification_token_verified_fingerprint => domain.verification_token_proof_fingerprint,
      :dkim_status => 'OK'
    )
    verified_response = domains_api_get('get', :id => domain.id)
    verified_data = verified_response.fetch('data')
    expect(verified_data).to include(
      'verification_token_status' => 'OK',
      'dkim_verified' => true
    )
    expect(verified_data.fetch('verification_token_verified_at')).to be_present
  end

  it 'rechecks exact root TXT verification for an already generically verified DNS domain' do
    domain = create(:domain, :owner => authenticated_server, :verification_method => 'DNS')
    domain.update_column(:verification_token_verified_at, nil)
    resolver = instance_double(Resolv::DNS)
    txt_record = instance_double(Resolv::DNS::Resource::IN::TXT, :data => domain.dns_verification_string)
    allow_any_instance_of(Domain).to receive(:check_dns).and_return(true)
    allow_any_instance_of(Domain).to receive(:resolver).and_return(resolver)
    allow(resolver).to receive(:getresources).with(domain.name, Resolv::DNS::Resource::IN::TXT).and_return([txt_record])

    response_payload = domains_api_get('verify', :id => domain.id)

    expect(response_payload.fetch('status')).to eq('success')
    expect(domain.reload.verification_token_verified_at).to be_present
    expect(response_payload.fetch('data')).to include('verification_token_status' => 'OK')
  end

  it 'invalidates stale DKIM verification when selector material changes' do
    domain = create(:domain, :owner => authenticated_server)
    domain.update_columns(:dkim_status => 'OK', :dkim_error => nil)
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    update_response = domains_api_get('update_single_dkim',
                                      :id => domain.id,
                                      :dkim_selector => 'venmail-newKey_1')
    get_response = domains_api_get('get', :id => domain.id)

    expect(update_response.fetch('status')).to eq('success')
    expect(domain.reload.dkim_status).to be_nil
    expect(get_response.fetch('data')).to include('dkim_status' => nil, 'dkim_verified' => false)
  end

  it 'keeps public list and get available for corrupt legacy DKIM material, then allows scoped regeneration' do
    domain = create(:domain, :owner => authenticated_server)
    domain.update_column(:dkim_private_key, 'corrupt legacy key material')

    get_response = domains_api_get('get', :id => domain.id)
    list_response = domains_api_get('list')

    expect(get_response.fetch('status')).to eq('success')
    get_data = get_response.fetch('data')
    expect(get_data).to include('dkim_record' => nil, 'dkim_material_status' => 'invalid')
    expect(get_data.fetch('dkim')).to include('record' => nil, 'status' => 'invalid')

    expect(list_response.fetch('status')).to eq('success')
    list_data = list_response.fetch('data').find { |entry| entry.fetch('id') == domain.id }
    expect(list_data).to include('dkim_record' => nil, 'dkim_material_status' => 'invalid')

    regenerate_response = domains_api_get('update_single_dkim', :id => domain.id, :regenerate => true)
    regenerate_data = regenerate_response.fetch('data')
    expect(regenerate_response.fetch('status')).to eq('success')
    expect(regenerate_data.fetch('dkim')).to include('status' => 'ready')
    expect(regenerate_data.fetch('dkim_record')).to start_with('v=DKIM1;')
  end

  it 'does not return another server domain by id or name' do
    other_domain = create(:domain, :owner => create(:server), :name => 'other-server.example')

    by_id = domains_api_get('get', :id => other_domain.id)
    by_name = domains_api_get('find_by_name', :name => other_domain.name)

    expect(by_id.fetch('status')).not_to eq('success')
    expect(by_name.fetch('status')).not_to eq('success')
  end

  it 'prefers the authenticated server domain over an organization domain with the same name' do
    shared_name = 'same-name.example'
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization, :name => shared_name)
    own_domain = create(:domain, :owner => authenticated_server, :name => shared_name)

    response_payload = domains_api_get('find_by_name', :name => shared_name, :include_private_key => true)

    expect(response_payload.fetch('status')).to eq('success')
    expect(response_payload.fetch('data').fetch('id')).to eq(own_domain.id)
    expect(response_payload.fetch('data').fetch('dkim_private_key')).to eq(own_domain.dkim_private_key)
    expect(response_payload.fetch('data').fetch('id')).not_to eq(organization_domain.id)
  end

  it 'accepts an explicit configured selector on create without returning the private key' do
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    response_payload = domains_api_get('domain',
                                       :name => 'selector-create.example',
                                       :dkim_selector => 'venmail-existingKey_1')
    data = response_payload.fetch('data')

    expect(response_payload.fetch('status')).to eq('success')
    expect(data).to include(
      'dkim_selector' => 'venmail-existingKey_1',
      'dkim_record_name' => 'venmail-existingKey_1._domainkey'
    )
    expect(data.fetch('dkim_record')).to start_with('v=DKIM1;')
    expect(data).not_to have_key('dkim_private_key')
  end

  it 'keeps private-key export available only for a domain directly owned by the authenticated server' do
    create_response = domains_api_get('domain', :name => 'private-export.example', :include_private_key => true)
    create_data = create_response.fetch('data')
    own_domain = Domain.find(create_data.fetch('id'))
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization)

    own_response = domains_api_get('get', :id => own_domain.id, :include_private_key => true)
    organization_response = domains_api_get('get', :id => organization_domain.id, :include_private_key => true)

    expect(create_response.fetch('status')).to eq('success')
    expect(create_data.fetch('dkim_private_key')).to eq(own_domain.dkim_private_key)
    expect(own_response.fetch('data').fetch('dkim_private_key')).to eq(own_domain.dkim_private_key)
    expect(organization_response.fetch('data')).not_to have_key('dkim_private_key')
  end

  it 'accepts a safe legacy suffix on create and derives the configured full selector' do
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    response_payload = domains_api_get('domain',
                                       :name => 'legacy-suffix.example',
                                       :dkim_identifier_string => 'existingKey_1')

    expect(response_payload.fetch('status')).to eq('success')
    expect(response_payload.fetch('data')).to include('dkim_selector' => 'venmail-existingKey_1')
  end

  it 'rejects unsafe legacy identifiers on create without persisting a domain' do
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    ['%dkim_data%', 'selector.name', ' selector', 'selector ', 'venmail-existingKey_1'].each_with_index do |identifier, index|
      name = "invalid-legacy-#{index}.example"
      response_payload = domains_api_get('domain', :name => name, :dkim_identifier_string => identifier)

      expect(response_payload.fetch('status')).not_to eq('success'), identifier
      expect(Domain.where(:name => name)).to be_empty
    end
  end

  it 'derives a BYODKIM public record from the supplied private key instead of trusting a supplied record' do
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')
    private_key = OpenSSL::PKey::RSA.new(2048).to_s
    public_key = OpenSSL::PKey::RSA.new(private_key).public_key.to_s.gsub(/-+[A-Z ]+-+\n/, '').gsub(/\n/, '')

    response_payload = domains_api_get('domain',
                                       :name => 'byodkim-record.example',
                                       :dkim_private_key => private_key,
                                       :dkim_selector => 'venmail-preservedKey',
                                       :dkim_record => 'v=DKIM1; p=untrusted;')
    data = response_payload.fetch('data')

    expect(response_payload.fetch('status')).to eq('success')
    expect(data.fetch('dkim_record')).to eq("v=DKIM1; t=s; h=sha256; p=#{public_key};")
    expect(data.fetch('dkim_record')).not_to include('untrusted')
    expect(data).not_to have_key('dkim_private_key')
  end

  it 'does not persist a domain when supplied BYODKIM material is invalid' do
    name = 'invalid-byodkim.example'

    response_payload = domains_api_get('domain',
                                       :name => name,
                                       :dkim_private_key => 'not a private key')

    expect(response_payload.fetch('status')).not_to eq('success')
    expect(Domain.where(:name => name)).to be_empty
  end

  it 'applies an explicit configured selector when regenerating a domain DKIM key' do
    domain = create(:domain, :owner => authenticated_server)
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    response_payload = domains_api_get('update_single_dkim',
                                       :id => domain.id,
                                       :regenerate => true,
                                       :dkim_selector => 'venmail-existingKey_2')
    data = response_payload.fetch('data')

    expect(response_payload.fetch('status')).to eq('success')
    expect(data).to include(
      'dkim_selector' => 'venmail-existingKey_2',
      'dkim_record_name' => 'venmail-existingKey_2._domainkey'
    )
    expect(data.fetch('dkim').fetch('record')).to start_with('v=DKIM1;')
    expect(data).not_to have_key('dkim_private_key')
    expect(OpenSSL::PKey::RSA.new(domain.reload.dkim_private_key).n.num_bits).to eq(2048)
  end

  it 'repairs corrupt persisted DKIM material with a fresh private key and public-only response' do
    domain = create(:domain, :owner => authenticated_server)
    domain.update_column(:dkim_private_key, 'corrupt legacy key material')
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    response_payload = domains_api_get('update_single_dkim', :id => domain.id, :regenerate => true)
    data = response_payload.fetch('data')

    expect(response_payload.fetch('status')).to eq('success')
    expect(OpenSSL::PKey::RSA.new(domain.reload.dkim_private_key).n.num_bits).to eq(2048)
    expect(data.fetch('dkim_selector')).to start_with('venmail-')
    expect(data.fetch('dkim_record_name')).to eq("#{data.fetch('dkim_selector')}._domainkey")
    expect(data.fetch('dkim_record')).to start_with('v=DKIM1;')
    expect(data.fetch('dkim')).to include('selector' => data.fetch('dkim_selector'), 'record' => data.fetch('dkim_record'))
    expect(data).not_to have_key('dkim_private_key')
  end

  it 'returns regenerated PEM only when the owning server explicitly requests it by domain ID' do
    domain = create(:domain, :owner => authenticated_server)
    domains_api_get('update_single_dkim', :id => domain.id, :regenerate => true)

    response_payload = domains_api_get('get', :id => domain.id, :include_private_key => true)
    data = response_payload.fetch('data')

    expect(response_payload.fetch('status')).to eq('success')
    expect(data.fetch('dkim_private_key')).to eq(domain.reload.dkim_private_key)
    expect(OpenSSL::PKey::RSA.new(data.fetch('dkim_private_key')).n.num_bits).to eq(2048)
  end

  it 'does not allow one server API key to regenerate another server domain' do
    other_domain = create(:domain, :owner => create(:server))
    original_key = other_domain.dkim_private_key

    response_payload = domains_api_get('update_single_dkim', :id => other_domain.id, :regenerate => true)
    private_get_response = domains_api_get('get', :id => other_domain.id, :include_private_key => true)

    expect(response_payload.fetch('status')).not_to eq('success')
    expect(private_get_response.fetch('status')).not_to eq('success')
    expect(other_domain.reload.dkim_private_key).to eq(original_key)
  end

  it 'does not bulk-rotate sibling server domains in the same organization' do
    sibling_server = create(:server, :organization => authenticated_server.organization, :name => 'Sibling Mail Server')
    own_domain = create(:domain, :owner => authenticated_server)
    sibling_domain = create(:domain, :owner => sibling_server)
    own_original_key = own_domain.dkim_private_key
    sibling_original_key = sibling_domain.dkim_private_key

    response_payload = domains_api_get('update_dkim',
                                       :organization_id => authenticated_server.organization.id,
                                       :regenerate_keys => true)

    expect(response_payload.fetch('status')).to eq('success')
    expect(own_domain.reload.dkim_private_key).not_to eq(own_original_key)
    expect(sibling_domain.reload.dkim_private_key).to eq(sibling_original_key)
  end

  it 'allows the authenticated server to retrieve and repair a domain owned by its organization' do
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization)
    original_key = organization_domain.dkim_private_key

    get_response = domains_api_get('get', :id => organization_domain.id, :include_private_key => true)
    regenerate_response = domains_api_get('update_single_dkim', :id => organization_domain.id, :regenerate => true)

    expect(get_response.fetch('status')).to eq('success')
    expect(get_response.fetch('data')).not_to have_key('dkim_private_key')
    expect(regenerate_response.fetch('status')).to eq('success')
    expect(organization_domain.reload.dkim_private_key).not_to eq(original_key)
  end

  it 'does not let a server API credential delete a shared organization domain' do
    organization_domain = create(:organization_domain, :owner => authenticated_server.organization)

    response_payload = domains_api_get('destroy', :id => organization_domain.id)

    expect(response_payload.fetch('status')).to eq('error')
    expect(Domain.where(:id => organization_domain.id)).to exist
  end

  it 'rejects unsafe legacy identifiers before a bulk update or dry run can mutate/report success' do
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')
    domain = create(:domain, :owner => authenticated_server, :dkim_identifier_string => 'A1B2C3')

    ['%dkim_data%', 'selector.name', ' selector', 'selector ', 'venmail-existingKey_1'].each do |identifier|
      response_payload = domains_api_get('update_dkim',
                                         :organization_id => authenticated_server.organization.id,
                                         :dkim_identifier_string => identifier,
                                         :dry_run => true)

      expect(response_payload.fetch('status')).not_to eq('success'), identifier
      expect(domain.reload.dkim_identifier_string).to eq('A1B2C3')
    end
  end

  it 'rejects a selector whose prefix does not match the configured service prefix' do
    domain = create(:domain, :owner => authenticated_server, :dkim_identifier_string => 'A1B2C3')
    allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

    response_payload = domains_api_get('update_single_dkim',
                                       :id => domain.id,
                                       :dkim_selector => 'other-existingKey_3')

    expect(response_payload.fetch('status')).not_to eq('success')
    expect(domain.reload.dkim_identifier_string).to eq('A1B2C3')
  end
end
