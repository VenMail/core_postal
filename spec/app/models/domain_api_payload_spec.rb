require 'rails_helper'

describe Domain do
  describe '.for_api_server' do
    it 'returns domains owned by the authenticated server or its organization, but not sibling servers' do
      authenticated_server = create(:server)
      sibling_server = create(:server, :organization => authenticated_server.organization, :name => 'Sibling Mail Server')
      other_server = create(:server)
      own_domain = create(:domain, :owner => authenticated_server, :name => 'shared-domain.example')
      organization_domain = create(:organization_domain, :owner => authenticated_server.organization)
      sibling_domain = create(:domain, :owner => sibling_server)
      other_domain = create(:domain, :owner => other_server, :name => 'shared-domain.example')

      scope = Domain.for_api_server(authenticated_server)

      expect(scope.find_by(:name => own_domain.name)).to eq(own_domain)
      expect(scope).to include(organization_domain)
      expect(scope).not_to include(sibling_domain)
      expect(scope.find_by(:id => other_domain.id)).to be_nil
    end
  end

  describe '#api_public_payload' do
    it 'returns the complete configured DNS ownership record' do
      domain = create(:domain, :owner => create(:server), :verification_token => 'tenant-token')
      allow(Postal.config.dns).to receive(:domain_verify_prefix).and_return('configured-prefix')

      expect(domain.api_public_payload).to include(
        :verification_token => 'tenant-token',
        :verification_record => 'configured-prefix tenant-token'
      )
    end

    it 'returns the configured DKIM selector and public DNS record without a private key' do
      domain = create(:domain, :owner => create(:server), :dkim_identifier_string => 'A1B2C3')
      allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')

      payload = domain.api_public_payload

      expect(payload).to include(
        :dkim_identifier => 'venmail-A1B2C3',
        :dkim_selector => 'venmail-A1B2C3',
        :dkim_record_name => 'venmail-A1B2C3._domainkey',
        :dkim_record => domain.dkim_record,
        :dkim => include(
          :selector => 'venmail-A1B2C3',
          :record_name => 'venmail-A1B2C3._domainkey',
          :record => domain.dkim_record,
          :status => 'ready'
        )
      )
      expect(payload).not_to have_key(:dkim_private_key)
      expect(payload[:dkim][:record]).not_to include(domain.dkim_private_key)
    end

    it 'returns a non-throwing invalid representation for corrupt persisted DKIM material' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_private_key, 'corrupt legacy key material')

      expect { domain.api_public_payload }.not_to raise_error
      payload = domain.api_public_payload

      expect(payload).to include(
        :dkim_record => nil,
        :dkim_material_status => 'invalid',
        :dkim => include(
          :selector => domain.dkim_identifier,
          :record_name => domain.dkim_record_name,
          :record => nil,
          :status => 'invalid'
        )
      )
    end

    it 'returns a non-throwing missing representation for nil persisted DKIM material' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_private_key, nil)

      payload = domain.api_public_payload

      expect(payload).to include(
        :dkim_record => nil,
        :dkim_material_status => 'missing',
        :dkim => include(:record => nil, :status => 'missing')
      )
    end

    it 'fails closed for persisted DKIM material below the required RSA key size' do
      domain = create(:domain, :owner => create(:server))
      domain.update_columns(
        :dkim_private_key => OpenSSL::PKey::RSA.new(1024).to_s,
        :dkim_status => 'OK'
      )

      expect(domain.api_public_payload).to include(
        :dkim_record => nil,
        :dkim_material_status => 'invalid',
        :dkim_verified => false,
        :dkim => include(:record => nil, :status => 'invalid')
      )
      expect { domain.check_dkim_record! }.not_to raise_error
      expect(domain.reload.dkim_status).to eq('Invalid')
    end

    it 'does not expose a legacy placeholder selector as a DNS record name' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_identifier_string, '%dkim_data%')

      expect(domain.dkim_identifier).to be_nil
      expect(domain.dkim_record_name).to be_nil
      expect(domain.api_public_payload).to include(
        :dkim_identifier => nil,
        :dkim_record_name => nil,
        :dkim_record => nil,
        :dkim_material_status => 'invalid'
      )
    end
  end

  describe '.dkim_identifier_string_for_selector' do
    before do
      allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')
    end

    it 'preserves the suffix from an explicitly supplied configured selector' do
      suffix = Domain.dkim_identifier_string_for_selector('venmail-existingKey_1')

      expect(suffix).to eq('existingKey_1')
      expect("venmail-#{suffix}").to eq('venmail-existingKey_1')
    end

    it 'rejects a selector with a different configured prefix instead of guessing' do
      expect {
        Domain.dkim_identifier_string_for_selector('other-existingKey_1')
      }.to raise_error(ArgumentError, /configured DKIM selector prefix/)
    end

    it 'rejects whitespace and unsafe selector characters instead of normalizing them' do
      [' venmail-existingKey_1', 'venmail-existingKey_1 ', 'venmail-%dkim_data%', 'venmail-key.name'].each do |selector|
        expect {
          Domain.dkim_identifier_string_for_selector(selector)
        }.to raise_error(ArgumentError)
      end
    end
  end

  describe '.dkim_identifier_string_for_suffix' do
    before do
      allow(Postal.config.dns).to receive(:dkim_identifier).and_return('venmail')
    end

    it 'accepts a safe legacy suffix without treating it as a full selector' do
      expect(Domain.dkim_identifier_string_for_suffix('existingKey_1')).to eq('existingKey_1')
    end

    it 'rejects placeholders, whitespace, dots, and duplicated configured prefixes' do
      ['%dkim_data%', 'selector.name', ' selector', 'selector ', ' ', 'venmail-existingKey_1'].each do |suffix|
        expect {
          Domain.dkim_identifier_string_for_suffix(suffix)
        }.to raise_error(ArgumentError)
      end
    end
  end

  describe 'DKIM identifier persistence' do
    it 'rejects an explicitly assigned invalid identifier before Nifty can replace it' do
      domain = build(:domain, :owner => create(:server), :dkim_identifier_string => ' %dkim_data% ')

      expect(domain).not_to be_valid
      expect(domain.errors[:dkim_identifier_string]).not_to be_empty
    end

    it 'leaves an untouched legacy invalid identifier repairable' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_identifier_string, '%legacy_placeholder%')
      domain.name = 'changed-name.example'

      expect(domain).to be_valid
    end
  end

  describe 'verification token contract' do
    it 'marks the root verification token as verified only after an exact DNS TXT match' do
      domain = create(:domain, :owner => create(:server), :verification_method => 'DNS')
      domain.update_columns(:verified_at => nil, :verification_token_verified_at => nil)
      resolver = instance_double(Resolv::DNS)
      txt_record = instance_double(Resolv::DNS::Resource::IN::TXT, :data => domain.dns_verification_string)
      allow(domain).to receive(:resolver).and_return(resolver)
      allow(resolver).to receive(:getresources).with(domain.name, Resolv::DNS::Resource::IN::TXT).and_return([txt_record])

      expect(domain.verify_with_dns).to be_truthy
      expect(domain.reload.verification_token_verified_at).to be_present
      expect(domain.verification_token_status).to eq('OK')
    end

    it 'does not mark the root verification token when MX or DKIM fallback sets generic verification' do
      domain = create(:domain, :owner => create(:server), :verification_method => 'DNS')
      domain.update_columns(:verified_at => nil, :verification_token_verified_at => nil)
      resolver = instance_double(Resolv::DNS)
      txt_record = instance_double(Resolv::DNS::Resource::IN::TXT, :data => 'wrong-token')
      allow(domain).to receive(:resolver).and_return(resolver)
      allow(resolver).to receive(:getresources).with(domain.name, Resolv::DNS::Resource::IN::TXT).and_return([txt_record])
      allow(domain).to receive(:check_mx_records) { domain.mx_status = 'OK' }
      allow(domain).to receive(:check_dkim_record)

      expect(domain.verify_with_dns).to be_truthy
      expect(domain.reload.verified_at).to be_present
      expect(domain.verification_token_verified_at).to be_nil
      expect(domain.verification_token_status).to eq('Pending')
    end

    it 'does not infer root token verification from generic force verification' do
      domain = create(:domain, :owner => create(:server))
      domain.update_columns(:verified_at => nil, :verification_token_verified_at => nil)

      domain.verify

      expect(domain.reload.verified_at).to be_present
      expect(domain.verification_token_verified_at).to be_nil
      expect(domain.verification_token_status).to eq('Pending')
    end

    it 'requires the recorded proof fingerprint to match the current DNS verification string' do
      domain = create(:domain, :owner => create(:server), :verification_method => 'DNS')
      domain.update_columns(
        :verification_token_verified_at => Time.now,
        :verification_token_verified_fingerprint => domain.verification_token_proof_fingerprint
      )

      expect(domain.verification_token_status).to eq('OK')

      allow(Postal.config.dns).to receive(:domain_verify_prefix).and_return('changed-proof-prefix')

      expect(domain.verification_token_status).to eq('Pending')
    end

    it 'reports pending root-token proof for email verification' do
      domain = create(:domain, :owner => create(:server), :verification_method => 'Email')
      domain.update_column(:verification_token_verified_at, nil)

      expect(domain.verification_token_status).to eq('Pending')
    end

    it 'clears the root token timestamp when the verification method regenerates its token' do
      domain = create(:domain, :owner => create(:server), :verification_method => 'DNS')
      domain.update_column(:verification_token_verified_at, Time.now)

      domain.update!(:verification_method => 'Email')

      expect(domain.reload.verification_token_verified_at).to be_nil
      expect(domain.verification_token_status).to eq('Pending')
    end

    it 'clears the root token timestamp whenever the verification token changes' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:verification_token_verified_at, Time.now)

      domain.update!(:verification_token => 'replacement-token')

      expect(domain.reload.verification_token_verified_at).to be_nil
      expect(domain.verification_token_status).to eq('Pending')
    end

    it 'clears the root token timestamp whenever the domain name changes' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:verification_token_verified_at, Time.now)

      domain.update!(:name => 'renamed-domain.example')

      expect(domain.reload.verification_token_verified_at).to be_nil
      expect(domain.verification_token_status).to eq('Pending')
    end
  end

  describe '#dkim_verified?' do
    it 'does not treat a stale OK status as verified when current key material is corrupt' do
      domain = create(:domain, :owner => create(:server))
      domain.update_columns(:dkim_private_key => 'corrupt legacy key material', :dkim_status => 'OK')

      expect(domain.dkim_verified?).to be(false)
      expect(domain.api_public_payload).to include(:dkim_status => 'OK', :dkim_verified => false)
    end

    it 'does not report DNS as healthy from a stale OK status when the current DKIM material is invalid' do
      domain = create(:domain, :owner => create(:server))
      domain.update_columns(
        :dkim_private_key => 'corrupt legacy key material',
        :dkim_status => 'OK',
        :spf_status => 'OK',
        :mx_status => 'Missing',
        :return_path_status => 'Missing'
      )

      expect(domain.dns_ok?).to be(false)
    end
  end

  describe 'corrupt DKIM material DNS checks' do
    it 'marks corrupt persisted material invalid instead of raising during a direct DKIM check' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_private_key, 'corrupt legacy key material')

      expect { domain.check_dkim_record! }.not_to raise_error
      expect(domain.reload).to have_attributes(
        :dkim_status => 'Invalid',
        :dkim_error => 'DKIM key material is missing or invalid; regenerate it before checking DNS.'
      )
    end

    it 'keeps the full DNS check available when persisted DKIM material is corrupt' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_private_key, 'corrupt legacy key material')
      allow(domain).to receive(:check_spf_record)
      allow(domain).to receive(:check_mx_records)
      allow(domain).to receive(:check_return_path_record)

      expect { domain.check_dns }.not_to raise_error
      expect(domain.reload.dkim_status).to eq('Invalid')
    end

    it 'does not raise when legacy code asks a corrupt domain directly for its DKIM record' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_private_key, 'corrupt legacy key material')

      expect { domain.dkim_record }.not_to raise_error
      expect(domain.dkim_record).to be_nil
    end
  end

  describe '#generate_dkim_key' do
    it 'creates a 2048-bit RSA key for new and regenerated DKIM material' do
      domain = build(:domain, :owner => create(:server))

      domain.generate_dkim_key
      expect(OpenSSL::PKey::RSA.new(domain.dkim_private_key).n.num_bits).to eq(2048)
      original_record = domain.dkim_record

      domain.regenerate_dkim_key
      expect(OpenSSL::PKey::RSA.new(domain.dkim_private_key).n.num_bits).to eq(2048)
      expect(domain.dkim_record).not_to eq(original_record)
    end
  end

  describe 'BYODKIM key validation' do
    it 'rejects malformed, undersized, and public-only RSA material before it can be persisted' do
      malformed_key_domain = build(:domain, :owner => create(:server), :dkim_private_key => 'not a private key')
      undersized_key_domain = build(:domain, :owner => create(:server), :dkim_private_key => OpenSSL::PKey::RSA.new(1024).to_s)
      public_only_key = OpenSSL::PKey::RSA.new(1024).public_key.to_s
      public_only_key_domain = build(:domain, :owner => create(:server), :dkim_private_key => public_only_key)

      expect(malformed_key_domain).not_to be_valid
      expect(malformed_key_domain.errors[:dkim_private_key]).to include('must be a valid RSA private key')
      expect(undersized_key_domain).not_to be_valid
      expect(undersized_key_domain.errors[:dkim_private_key]).to include('must be at least 2048 bits')
      expect(public_only_key_domain).not_to be_valid
      expect(public_only_key_domain.errors[:dkim_private_key]).to include('must be a valid RSA private key')
    end

    it 'returns a validation error rather than raising when a private key is cleared' do
      domain = create(:domain, :owner => create(:server))
      domain.dkim_private_key = nil

      expect { domain.valid? }.not_to raise_error
      expect(domain.errors[:dkim_private_key]).to include('must be a valid RSA private key')
    end
  end

  describe '#as_json' do
    it 'never serializes the DKIM private key, including an explicit only request' do
      domain = create(:domain, :owner => create(:server))

      expect(domain.as_json).not_to have_key('dkim_private_key')
      expect(domain.as_json(:only => [:dkim_private_key])).not_to have_key('dkim_private_key')
      expect(domain.as_json(:methods => [:dkim_private_key])).not_to have_key('dkim_private_key')
    end
  end
end
