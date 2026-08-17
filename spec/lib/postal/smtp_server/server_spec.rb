require 'spec_helper'
require 'socket'
require 'openssl'
require File.expand_path('../../../../lib/postal/smtp_server/server', __dir__)

RSpec.describe Postal::SMTPServer::Server do
  class TestMonitor
    attr_accessor :interests

    def initialize(interests)
      @interests = interests
    end
  end

  it 'keeps a stalled TLS handshake non-blocking' do
    listener = TCPServer.new('127.0.0.1', 0)
    peer = TCPSocket.new('127.0.0.1', listener.local_address.ip_port)
    socket = listener.accept
    tls_socket = OpenSSL::SSL::SSLSocket.new(socket, OpenSSL::SSL::SSLContext.new)
    monitor = TestMonitor.new(:r)
    handshakes = {}
    client = instance_double('Postal::SMTPServer::Client', log: true)
    server = described_class.allocate

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = server.send(:advance_tls_handshake, tls_socket, monitor, client, handshakes)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(result).to eq(:pending)
    expect(elapsed).to be < 0.5
    expect(monitor.interests).to eq(:r)
    expect(handshakes).to have_key(tls_socket)
  ensure
    tls_socket&.close
    peer&.close
    listener&.close
  end
end
