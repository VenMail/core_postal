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

  it 'matches configured IPv4 and IPv6 CIDRs' do
    configured = ['203.0.113.0/24', '2001:db8::/32']

    expect(described_class.configured_source_trusted?('203.0.113.44', configured)).to eq(true)
    expect(described_class.configured_source_trusted?('2001:db8::44', configured)).to eq(true)
    expect(described_class.configured_source_trusted?('198.51.100.44', configured)).to eq(false)
  end

  it 'does not implicitly trust the control network for configured-only provenance' do
    expect(described_class.configured_source_trusted?('172.19.0.12', whitelist)).to eq(false)
  end

  it 'ignores malformed configured ranges and fails closed for an invalid source' do
    expect(described_class.configured_source_trusted?('203.0.113.44', ['not-a-range', '203.0.113.0/24'])).to eq(true)
    expect(described_class.configured_source_trusted?('not-an-ip', ['203.0.113.0/24'])).to eq(false)
  end

  it 'fails closed when the configured key is empty' do
    request = Request.new({ 'X-Master-Key' => '' }, '172.19.0.12')

    expect(described_class.trusted?(request, :expected_master_key => '', :whitelist => whitelist)).to eq(false)
  end
end
