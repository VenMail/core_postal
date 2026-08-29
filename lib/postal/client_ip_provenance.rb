require 'ipaddr'
require 'digest'
require 'postal/api_request_trust'

module Postal
  module ClientIpProvenance
    HEADER = 'X-Venmail-Client-IP'.freeze
    MAX_LENGTH = 42

    Result = Struct.new(
      :transport_peer_ip,
      :external_actor_ip,
      :trusted_gateway,
      :status,
      :keyword_init => true
    )

    def self.resolve(request, expected_master_key:, whitelist:)
      peer = normalize(request.ip)
      trusted = Postal::ApiRequestTrust.key_valid?(
        request.headers['X-Master-Key'].to_s,
        expected_master_key.to_s
      ) && Postal::ApiRequestTrust.configured_source_trusted?(request.ip, whitelist)

      unless trusted
        return Result.new(
          :transport_peer_ip => peer,
          :external_actor_ip => nil,
          :trusted_gateway => false,
          :status => :untrusted_gateway
        )
      end

      raw_actor = request.headers[HEADER].to_s
      if raw_actor.empty?
        return Result.new(
          :transport_peer_ip => peer,
          :external_actor_ip => nil,
          :trusted_gateway => true,
          :status => :missing
        )
      end

      actor = normalize(raw_actor)
      Result.new(
        :transport_peer_ip => peer,
        :external_actor_ip => actor,
        :trusted_gateway => true,
        :status => actor ? :accepted : :invalid
      )
    end

    def self.normalize(value)
      text = value.to_s.strip.sub(/%[^%]+\z/, '').sub(/\A::ffff:/i, '')
      return nil if text.empty?

      canonical = IPAddr.new(text).to_s.downcase
      canonical.length <= MAX_LENGTH ? canonical : nil
    rescue IPAddr::InvalidAddressError
      nil
    end

    def self.log_diagnostic(result, credential)
      return unless result.trusted_gateway && [:missing, :invalid].include?(result.status)

      peer_hash = Digest::SHA256.hexdigest(result.transport_peer_ip.to_s)[0, 16]
      cache_key = "postal:client-ip-provenance:#{result.status}:#{peer_hash}"
      Rails.cache.fetch(cache_key, :expires_in => 5.minutes) do
        Rails.logger.warn(
          "Client IP provenance status=#{result.status} peer_hash=#{peer_hash} " \
          "credential_id=#{credential.id} server_id=#{credential.server_id}"
        )
        true
      end
    end
  end
end
