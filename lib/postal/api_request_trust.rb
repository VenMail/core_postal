require 'active_support/security_utils'
require 'digest'
require 'ipaddr'

module Postal
  module ApiRequestTrust
    CONTROL_NETWORK = IPAddr.new('172.19.0.0/24').freeze

    def self.trusted?(request, expected_master_key:, whitelist:)
      provided_key = request.headers['X-Master-Key'].to_s
      expected_key = expected_master_key.to_s

      key_valid?(provided_key, expected_key) && source_trusted?(request.ip, whitelist)
    end

    def self.key_valid?(provided_key, expected_key)
      return false if provided_key.to_s.empty? || expected_key.to_s.empty?

      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(provided_key.to_s),
        Digest::SHA256.hexdigest(expected_key.to_s)
      )
    end

    def self.source_trusted?(source_ip, whitelist)
      address = IPAddr.new(source_ip.to_s)

      CONTROL_NETWORK.include?(address) || configured_source_trusted?(source_ip, whitelist)
    rescue IPAddr::InvalidAddressError
      false
    end

    def self.configured_source_trusted?(source_ip, whitelist)
      address = IPAddr.new(source_ip.to_s)

      Array(whitelist).any? do |entry|
        IPAddr.new(entry.to_s).include?(address)
      rescue IPAddr::InvalidAddressError
        false
      end
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
