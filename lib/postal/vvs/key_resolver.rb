require 'net/http'
require 'json'
require 'resolv'

module Postal
  module VVS
    class KeyResolver

      CACHE = {}
      DEFAULT_CACHE_TTL = 300

      def self.cache_ttl
        Postal.config.vvs&.key_cache_ttl || DEFAULT_CACHE_TTL
      end

      def self.resolve(agent_name, domain, method, embedded_key: nil)
        cache_key = "#{method}:#{agent_name}@#{domain}"
        cached = CACHE[cache_key]
        if cached && cached[:expires] > Time.now.to_i
          return cached[:data]
        end

        result = case method
        when 'well-known'
          resolve_well_known(agent_name, domain)
        when 'dns'
          resolve_dns(agent_name, domain)
        when 'embedded'
          return nil unless embedded_key
          { key: embedded_key, status: 'active' }
        else
          nil
        end

        if result
          CACHE[cache_key] = { data: result, expires: Time.now.to_i + cache_ttl }
        end
        result
      end

      def self.clear_cache!
        CACHE.clear
      end

      private

      def self.resolve_well_known(agent_name, domain)
        uri = URI("https://#{domain}/.well-known/venmail-agent/#{agent_name}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5
        response = http.get(uri.path)
        return nil unless response.code == '200'

        data = JSON.parse(response.body)
        return nil unless data['status'] == 'active'
        { key: data['public_key'], key_version: data['key_version'], status: data['status'] }
      rescue
        nil
      end

      def self.resolve_dns(agent_name, domain)
        resolver = Resolv::DNS.new
        resources = resolver.getresources("_venmail.#{domain}", Resolv::DNS::Resource::IN::TXT)
        resources.each do |resource|
          txt = resource.strings.join('')
          next unless txt.start_with?('v=VVS1')

          parts = {}
          txt.split(';').each do |part|
            k, v = part.strip.split('=', 2)
            parts[k&.strip] = v&.strip
          end

          next unless parts['agent'] == agent_name

          return {
            key: parts['pubkey'],
            key_version: parts['kv']&.to_i,
            status: parts['status'] || 'active'
          }
        end
        nil
      rescue
        nil
      end

    end
  end
end
