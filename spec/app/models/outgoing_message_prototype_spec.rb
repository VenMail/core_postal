require 'rails_helper'

describe OutgoingMessagePrototype do

  it "should create a new message" do
    with_global_server do |server|
      domain = create(:domain, :owner => server)
      Route.create!(:server => server, :domain => domain, :name => 'test', :mode => 'Accept', :spam_mode => 'Mark')
      prototype = OutgoingMessagePrototype.new(server, '127.0.0.1', 'TestSuite', {
        :from => "test@#{domain.name}",
        :to => "test@example.com",
        :subject => "Test Message",
        :plain_body => "A plain body!"
      })

      expect(prototype.valid?).to be true
      message = prototype.create_message('test@example.com')
      expect(message).to be_a Hash
      expect(message[:id]).to be_a Integer
      expect(message[:token]).to be_a String
    end
  end

  it 'stores the transport peer separately and uses the external actor as sender_ip' do
    with_global_server do |server|
      domain = create(:domain, :owner => server)
      Route.create!(:server => server, :domain => domain, :name => 'test', :mode => 'Accept', :spam_mode => 'Mark')
      gateway_ip = '2a03:4000:15:e61:281d:40ff:fe8d:c8d2'
      actor_ip = '198.51.100.23'
      prototype = OutgoingMessagePrototype.new(server, gateway_ip, 'TestSuite', {
        :from => "test@#{domain.name}",
        :to => 'test@example.com',
        :subject => 'Test Message',
        :plain_body => 'A plain body!'
      }, :external_actor_ip => actor_ip)

      stored = server.message_db.message(prototype.create_message('test@example.com').fetch(:id))

      expect(stored.transport_peer_ip).to eq(gateway_ip)
      expect(stored.external_actor_ip).to eq(actor_ip)
      expect(stored.sender_ip).to eq(actor_ip)
      expect(stored.raw_headers).to include(gateway_ip)
      expect(stored.raw_headers).not_to include(actor_ip)
    end
  end

  it 'falls back to the Received header for legacy messages without stored provenance' do
    with_global_server do |server|
      message = server.message_db.new_message
      message.scope = 'outgoing'
      message.rcpt_to = 'test@example.com'
      message.mail_from = 'sender@example.com'
      message.raw_message = "Received: from legacy.example [203.0.113.81]\r\nSubject: Legacy\r\n\r\nbody"
      message.save

      stored = server.message_db.message(message.id)

      expect(stored.external_actor_ip).to be_nil
      expect(stored.transport_peer_ip).to be_nil
      expect(stored.sender_ip).to eq('203.0.113.81')
    end
  end

end
