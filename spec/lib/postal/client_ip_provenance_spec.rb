require 'rails_helper'
require 'postal/client_ip_provenance'

RSpec.describe 'Postal client IP provenance' do
  ProvenanceRequest = Struct.new(:headers, :ip)

  let(:expected_key) { 'configured-master-key' }
  let(:whitelist) { ['203.0.113.0/24', '2001:db8::10'] }

  def resolve(peer: '203.0.113.10', key: expected_key, actor: '198.51.100.23')
    headers = { 'X-Master-Key' => key }
    headers['X-Venmail-Client-IP'] = actor unless actor.nil?
    request = ProvenanceRequest.new(headers, peer)

    Postal::ClientIpProvenance.resolve(
      request,
      :expected_master_key => expected_key,
      :whitelist => whitelist
    )
  end

  it 'accepts provenance only from a configured gateway with the master key' do
    result = resolve

    expect(result.trusted_gateway).to eq(true)
    expect(result.transport_peer_ip).to eq('203.0.113.10')
    expect(result.external_actor_ip).to eq('198.51.100.23')
    expect(result.status).to eq(:accepted)
  end

  it 'canonicalizes IPv4-mapped IPv6 and IPv6 zone identifiers' do
    expect(resolve(:actor => '::ffff:198.51.100.23').external_actor_ip).to eq('198.51.100.23')
    expect(resolve(:actor => 'fe80::1%eth0').external_actor_ip).to eq('fe80::1')
    expect(resolve(:actor => '2001:0db8:0:0:0:0:0:1').external_actor_ip).to eq('2001:db8::1')
  end

  it 'ignores the actor header when the master key is invalid' do
    result = resolve(:key => 'wrong')

    expect(result.trusted_gateway).to eq(false)
    expect(result.external_actor_ip).to be_nil
    expect(result.status).to eq(:untrusted_gateway)
  end

  it 'ignores the actor header when the peer is not explicitly configured' do
    result = resolve(:peer => '172.19.0.12')

    expect(result.trusted_gateway).to eq(false)
    expect(result.external_actor_ip).to be_nil
  end

  it 'distinguishes missing and invalid actor headers' do
    expect(resolve(:actor => nil).status).to eq(:missing)

    invalid = resolve(:actor => 'not-an-ip-address')
    expect(invalid.status).to eq(:invalid)
    expect(invalid.external_actor_ip).to be_nil
  end

  it 'rejects over-width values before storage' do
    result = resolve(:actor => '1' * 43)

    expect(result.status).to eq(:invalid)
    expect(result.external_actor_ip).to be_nil
  end
end
