require 'rails_helper'
require 'postal/api_request_trust'

RSpec.describe Postal::ApiRequestTrust do
  Request = Struct.new(:headers, :ip)

  let(:expected_key) { 'configured-master-key' }
  let(:whitelist) { ['203.0.113.10', '2001:db8::10'] }

  it 'trusts a valid key from a whitelisted IPv6 address' do
    request = Request.new({ 'X-Master-Key' => expected_key }, '2001:db8::10')

    expect(described_class.trusted?(request, :expected_master_key => expected_key, :whitelist => whitelist)).to eq(true)
  end

  it 'rejects an invalid key from a whitelisted address' do
    request = Request.new({ 'X-Master-Key' => 'wrong' }, '2001:db8::10')

    expect(described_class.trusted?(request, :expected_master_key => expected_key, :whitelist => whitelist)).to eq(false)
  end

  it 'rejects a valid key from a public non-whitelisted address' do
    request = Request.new({ 'X-Master-Key' => expected_key }, '198.51.100.30')

    expect(described_class.trusted?(request, :expected_master_key => expected_key, :whitelist => whitelist)).to eq(false)
  end

  it 'trusts a valid key from the private control network' do
    request = Request.new({ 'X-Master-Key' => expected_key }, '172.19.0.12')

    expect(described_class.trusted?(request, :expected_master_key => expected_key, :whitelist => whitelist)).to eq(true)
  end

  it 'fails closed when the configured key is empty' do
    request = Request.new({ 'X-Master-Key' => '' }, '172.19.0.12')

    expect(described_class.trusted?(request, :expected_master_key => '', :whitelist => whitelist)).to eq(false)
  end
end
