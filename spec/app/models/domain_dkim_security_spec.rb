require 'rails_helper'

RSpec.describe Domain do
  describe 'DKIM key generation and export safety' do
    it 'generates a 2048-bit private key for a new domain' do
      domain = create(:domain, :owner => create(:server))

      expect(OpenSSL::PKey::RSA.new(domain.dkim_private_key).n.num_bits).to be >= 2048
    end

    it 'regenerates a new 2048-bit key and selector only when explicitly requested' do
      domain = create(:domain, :owner => create(:server))
      original_private_key = domain.dkim_private_key
      original_identifier = domain.dkim_identifier_string

      domain.regenerate_dkim_key

      expect(OpenSSL::PKey::RSA.new(domain.dkim_private_key).n.num_bits).to be >= 2048
      expect(domain.dkim_private_key).not_to eq(original_private_key)
      expect(domain.dkim_identifier_string).not_to eq(original_identifier)
    end

    it 'keeps an existing legacy 1024-bit key until an explicit update changes it' do
      domain = create(:domain, :owner => create(:server))
      legacy_private_key = OpenSSL::PKey::RSA.new(1024).to_s
      domain.update_column(:dkim_private_key, legacy_private_key)
      domain.reload

      domain.update!(:name => 'legacy-key-renamed.example')

      expect(domain.reload.dkim_private_key).to eq(legacy_private_key)
    end

    it 'rejects a changed private key below 2048 bits' do
      domain = create(:domain, :owner => create(:server))
      domain.dkim_private_key = OpenSSL::PKey::RSA.new(1024).to_s

      expect(domain).not_to be_valid
      expect(domain.errors[:dkim_private_key]).to include('must be at least 2048 bits')
    end

    it 'returns a validation error rather than raising when private material is cleared' do
      domain = create(:domain, :owner => create(:server))
      domain.dkim_private_key = nil

      expect { domain.valid? }.not_to raise_error
      expect(domain.errors[:dkim_private_key]).to include('must be a valid RSA private key')
    end

    it 'rejects a changed DKIM identifier string containing a placeholder' do
      domain = create(:domain, :owner => create(:server))
      domain.dkim_identifier_string = '%dkim_data%'

      expect(domain).not_to be_valid
      expect(domain.errors[:dkim_identifier_string]).to include('must be a valid DKIM selector suffix')
    end

    it 'never includes the DKIM private key in generic JSON serialization' do
      domain = create(:domain, :owner => create(:server))

      expect(domain.as_json).not_to have_key('dkim_private_key')
      expect(domain.as_json(:only => [:dkim_private_key])).not_to have_key('dkim_private_key')
      expect(domain.as_json(:methods => [:dkim_private_key])).not_to have_key('dkim_private_key')
    end

    it 'does not perform a DNS lookup for a legacy placeholder selector' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_identifier_string, '%dkim_data%')
      domain.reload

      expect(domain).not_to receive(:resolver)
      expect { domain.check_dkim_record! }.not_to raise_error
      expect(domain.reload).to have_attributes(
        :dkim_status => 'Invalid',
        :dkim_error => 'DKIM selector is missing or invalid; regenerate it before checking DNS.'
      )
    end

    it 'marks missing legacy private material invalid without raising during DNS verification' do
      domain = create(:domain, :owner => create(:server))
      domain.update_column(:dkim_private_key, nil)
      domain.reload

      expect(domain).not_to receive(:resolver)
      expect { domain.check_dkim_record! }.not_to raise_error
      expect(domain.reload).to have_attributes(
        :dkim_status => 'Invalid',
        :dkim_error => 'DKIM key material is missing or invalid; regenerate it before checking DNS.'
      )
    end
  end
end
