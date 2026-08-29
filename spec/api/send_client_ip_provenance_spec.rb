require 'rails_helper'
require 'json'

RSpec.describe 'Send API client IP provenance' do
  let(:server) { Server.find(GLOBAL_SERVER.id) }
  let(:credential) { create(:credential, :api, :server => server) }
  let(:master_key) { 'configured-master-key' }
  let(:gateway_ip) { '2a03:4000:15:e61:281d:40ff:fe8d:c8d2' }
  let(:actor_ip) { '198.51.100.23' }

  around do |example|
    old_master_key = Postal.config.general.master_api_key
    old_whitelist = Postal.config.general.respond_to?(:whitelist) ? Postal.config.general.whitelist : nil
    Postal.config.general.master_api_key = master_key
    Postal.config.general.whitelist = [gateway_ip]
    example.run
  ensure
    Postal.config.general.master_api_key = old_master_key
    Postal.config.general.whitelist = old_whitelist
    server.message_db.provisioner.clean if defined?(server) && server
  end

  def post_json(path, params, peer: gateway_ip, headers: {})
    post path,
         :params => params.to_json,
         :headers => {
           'CONTENT_TYPE' => 'application/json',
           'X-Server-API-Key' => credential.key,
           'X-Master-Key' => master_key,
           'X-Venmail-Client-IP' => actor_ip,
           'REMOTE_ADDR' => peer
         }.merge(headers)
    JSON.parse(response.body)
  end

  def authorize_sender
    domain = create(:domain, :owner => server)
    Route.create!(
      :server => server,
      :domain => domain,
      :name => 'sender',
      :mode => 'Accept',
      :spam_mode => 'Mark'
    )
    "sender@#{domain.name}"
  end

  it 'stores trusted actor provenance for structured messages' do
    sender = authorize_sender
    payload = post_json('/api/v1/send/message', {
      :to => ['recipient@example.com'],
      :from => sender,
      :subject => 'Structured provenance',
      :plain_body => 'body'
    })

    message_id = payload.fetch('data').fetch('messages').fetch('recipient@example.com').fetch('id')
    message = server.message_db.message(message_id)

    expect(message.transport_peer_ip).to eq(gateway_ip)
    expect(message.external_actor_ip).to eq(actor_ip)
    expect(message.sender_ip).to eq(actor_ip)
    expect(message.raw_headers).to include(gateway_ip)
    expect(message.raw_headers).not_to include(actor_ip)
  end

  it 'stores trusted actor provenance for raw messages' do
    sender = authorize_sender
    raw_message = "From: #{sender}\r\nTo: recipient@example.com\r\nSubject: Raw provenance\r\n\r\nbody"
    payload = post_json('/api/v1/send/raw', {
      :mail_from => sender,
      :rcpt_to => ['recipient@example.com'],
      :data => Base64.strict_encode64(raw_message)
    })

    message_id = payload.fetch('data').fetch('messages').fetch('recipient@example.com').fetch('id')
    message = server.message_db.message(message_id)

    expect(message.transport_peer_ip).to eq(gateway_ip)
    expect(message.external_actor_ip).to eq(actor_ip)
    expect(message.sender_ip).to eq(actor_ip)
    expect(message.raw_headers).not_to include(actor_ip)
  end

  it 'ignores a claimed actor from an untrusted peer and attributes the direct API request to its peer' do
    direct_peer = '203.0.113.92'
    sender = authorize_sender
    payload = post_json(
      '/api/v1/send/message',
      {
        :to => ['recipient@example.com'],
        :from => sender,
        :subject => 'Direct API peer',
        :plain_body => 'body'
      },
      :peer => direct_peer
    )

    message_id = payload.fetch('data').fetch('messages').fetch('recipient@example.com').fetch('id')
    message = server.message_db.message(message_id)

    expect(message.transport_peer_ip).to eq(direct_peer)
    expect(message.external_actor_ip).to be_nil
    expect(message.sender_ip).to eq(direct_peer)
  end

  it 'attributes raw direct API requests to the stored peer without trusting a claimed actor' do
    direct_peer = '203.0.113.93'
    sender = authorize_sender
    raw_message = "From: #{sender}\r\nTo: recipient@example.com\r\nSubject: Raw direct peer\r\n\r\nbody"
    payload = post_json(
      '/api/v1/send/raw',
      {
        :mail_from => sender,
        :rcpt_to => ['recipient@example.com'],
        :data => Base64.strict_encode64(raw_message)
      },
      :peer => direct_peer
    )

    message_id = payload.fetch('data').fetch('messages').fetch('recipient@example.com').fetch('id')
    message = server.message_db.message(message_id)

    expect(message.transport_peer_ip).to eq(direct_peer)
    expect(message.external_actor_ip).to be_nil
    expect(message.sender_ip).to eq(direct_peer)
  end
end
