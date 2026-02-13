require 'rails_helper'

describe Postal::HTTPSender do
  it 'includes from_ip when delivering to HTTP endpoint (Hash format)' do
    with_global_server do |server|
      message = server.message_db.new_message
      message.scope = 'incoming'
      message.rcpt_to = 'test@example.com'
      message.mail_from = 'sender@example.net'
      message.raw_message = "Received: from client (client [203.0.113.10]) by mx.example.com with SMTP; #{Time.now.utc.rfc2822}\r\nDKIM-Signature: v=1; a=rsa-sha256; d=example.net; s=default; bh=abc123; b=xyz\r\nSubject: Test\r\nTo: test@example.com\r\nFrom: sender@example.net\r\n\r\nHello"
      message.save

      endpoint = double(
        url: 'https://example.com/endpoint',
        timeout: 5,
        encoding: 'BodyAsJSON',
        format: 'Hash',
        strip_replies: false,
        include_attachments?: false
      )

      sender = Postal::HTTPSender.new(endpoint)

      expect(Postal::HTTP).to receive(:post) do |_url, options|
        parsed = JSON.parse(options[:json])
        expect(parsed['from_ip']).to eq('203.0.113.10')
        expect(parsed['dkim_signed']).to eq(true)
        expect(parsed['dkim_signature']).to eq('v=1; a=rsa-sha256; d=example.net; s=default; bh=abc123; b=xyz')
        { code: 200, body: 'OK', secure: true }
      end

      sender.send_message(message)
    end
  end

  it 'includes from_ip when delivering to HTTP endpoint (RawMessage format)' do
    with_global_server do |server|
      message = server.message_db.new_message
      message.scope = 'incoming'
      message.rcpt_to = 'test@example.com'
      message.mail_from = 'sender@example.net'
      message.raw_message = "Received: from client (client [198.51.100.55]) by mx.example.com with SMTP; #{Time.now.utc.rfc2822}\r\nDKIM-Signature: v=1; a=rsa-sha256; d=example.org; s=default; bh=def456; b=uvw\r\nSubject: Test\r\nTo: test@example.com\r\nFrom: sender@example.net\r\n\r\nHello"
      message.save

      endpoint = double(
        url: 'https://example.com/endpoint',
        timeout: 5,
        encoding: 'BodyAsJSON',
        format: 'RawMessage',
        strip_replies: false,
        include_attachments?: false
      )

      sender = Postal::HTTPSender.new(endpoint)

      expect(Postal::HTTP).to receive(:post) do |_url, options|
        parsed = JSON.parse(options[:json])
        expect(parsed['from_ip']).to eq('198.51.100.55')
        expect(parsed['dkim_signed']).to eq(true)
        expect(parsed['dkim_signature']).to eq('v=1; a=rsa-sha256; d=example.org; s=default; bh=def456; b=uvw')
        { code: 200, body: 'OK', secure: true }
      end

      sender.send_message(message)
    end
  end
end
