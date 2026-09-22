require 'spec_helper'
require 'openssl'
require 'time'
require File.expand_path('../../../../lib/postal/config', __dir__)
require File.expand_path('../../../../lib/postal/smtp_server/client', __dir__)

RSpec.describe Postal::SMTPServer::Client do
  let(:address) { 'disabled@example.test' }
  let(:mail_users) { double('mail users') }
  let(:message_db) { double('message database', :mail_user => mail_users) }
  let(:server) { double('server', :suspended? => false, :message_db => message_db) }
  let(:domain) { double('domain', :owner => server) }
  let(:domain_query) { double('domain query') }
  let(:client) { described_class.allocate }

  before do
    stub_const('Postal::Helpers', Module.new do
      def self.strip_name_from_address(address)
        address
      end
    end)
    stub_const('Domain', Class.new do
      def self.includes(_association); end
    end)
    allow(Domain).to receive(:includes).with(:owner).and_return(domain_query)
    allow(domain_query).to receive(:where).with('LOWER(domains.name) = ?', 'example.test').and_return(domain_query)
    allow(domain_query).to receive(:first).and_return(domain)
    allow(client).to receive(:log)
    allow(UnixCrypt).to receive(:valid?).and_return(true)
    allow(Postal).to receive(:config).and_return(double(
      'postal config',
      :dns => double('dns config', :smtp_server_hostname => 'smtp.example.test'),
      :smtp_server => double('smtp config', :strip_received_headers? => false,
                           :max_message_size => double('size limit', :megabytes => 1_048_576))
    ))
  end

  [false, 0, '0'].each do |inactive_value|
    it "rejects a mailbox marked inactive with #{inactive_value.inspect}" do
      allow(mail_users).to receive(:find).with(address).and_return('password' => '12345678901234hash', 'active' => inactive_value)

      expect(client.send(:valid_user_authentication?, address, 'correct-password')).to eq(false)
      expect(UnixCrypt).not_to have_received(:valid?)
    end
  end

  it 'continues authenticating an active mailbox' do
    allow(mail_users).to receive(:find).with(address).and_return('password' => '12345678901234hash', 'active' => true)
    allow(mail_users).to receive(:update_login).with(address)

    expect(client.send(:valid_user_authentication?, address, 'correct-password')).to eq(true)
    expect(mail_users).to have_received(:update_login).with(address)
  end

  it 'rejects DATA if the authenticated mailbox was deactivated after login' do
    client.instance_variable_set(:@state, :rcpt_to_received)
    client.instance_variable_set(:@server, server)
    client.instance_variable_set(:@authenticated_user_email, address)
    client.instance_variable_set(:@domain, domain)
    allow(mail_users).to receive(:find).with(address).and_return('active' => false)

    expect(client.send(:data, 'DATA')).to eq('535 Authenticated mailbox is inactive')
    expect(client.instance_variable_get(:@authenticated_user_email)).to be_nil
    expect(client.instance_variable_get(:@domain)).to be_nil
  end

  it 'rejects message completion if the mailbox was deactivated during DATA' do
    client.instance_variable_set(:@server, server)
    client.instance_variable_set(:@authenticated_user_email, address)
    client.instance_variable_set(:@domain, domain)
    client.instance_variable_set(:@data, ''.force_encoding('BINARY'))
    client.instance_variable_set(:@headers, {})
    client.instance_variable_set(:@recipients, [])
    allow(mail_users).to receive(:find).with(address).and_return('active' => false)

    expect(client.send(:finished)).to eq('535 Authenticated mailbox is inactive')
    expect(client.instance_variable_get(:@authenticated_user_email)).to be_nil
    expect(client.instance_variable_get(:@domain)).to be_nil
  end

  it 'records the authenticated SMTP peer IP on each outgoing message' do
    sender_domain = double('sender domain', :name => 'example.test', :id => 5)
    outbound_server = double('outbound server', :block_outgoing_without_verified_route? => false)
    credential = double('credential', :id => 7, :server => outbound_server)
    message = double('outgoing message').as_null_object
    outbound_db = double('message database', :new_message => message)
    allow(outbound_server).to receive(:authenticated_sender_from_headers)
      .and_return(:domain => sender_domain, :address => address)
    allow(outbound_server).to receive(:message_db).and_return(outbound_db)
    allow(client).to receive(:client_ip_banned?).and_return(false)
    client.instance_variable_set(:@credential, credential)
    client.instance_variable_set(:@ip_address, '204.10.162.167')
    client.instance_variable_set(:@mail_from, address)
    client.instance_variable_set(:@data, "From: #{address}\r\n\r\nbody".force_encoding('BINARY'))
    client.instance_variable_set(:@headers, { 'from' => [address] })
    client.instance_variable_set(:@recipients, [[:credential, 'recipient@example.org', outbound_server, {}]])

    expect(message).to receive(:transport_peer_ip=).with('204.10.162.167')
    expect(message).to receive(:trusted_gateway=).with(0)
    expect(message).to receive(:authenticated_mailbox=).with(address)
    expect(client.send(:finished)).to eq('250 OK')
  end
end
