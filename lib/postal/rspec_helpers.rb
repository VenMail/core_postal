module Postal
  module RspecHelpers

    def with_global_server(&block)
      server = Server.find(GLOBAL_SERVER.id)
      block.call(server)
    ensure
      server.message_db.provisioner.clean
    end

    def create_plain_text_message(server, text, to  = 'test@example.com', override_attributes = {})
      domain = create(:domain, :owner => server)
      attributes = {:from => "test@#{domain.name}", :subject => "Test Plain Text Message"}.merge(override_attributes)
      attributes[:to] = to
      attributes[:plain_body] = text
      message = OutgoingMessagePrototype.new(server, '127.0.0.1', 'testsuite', attributes)
      result = message.create_message(to)
      server.message_db.message(result[:id])
    end

    # Helper methods for generating test data
    def generate_ip_address
      "192.168.#{rand(1..255)}.#{rand(1..255)}"
    end

    def generate_email
      "test#{rand(1000..9999)}@example.com"
    end

    def generate_username
      "user_#{rand(1000..9999)}"
    end

    def generate_password
      SecureRandom.hex(16)
    end

    def generate_token
      SecureRandom.hex(32)
    end

    def generate_uuid
      SecureRandom.uuid
    end

  end
end
