require 'json'

module Postal
  class AvailableRouteLookup
    DEFAULT_URLS = [
      'https://m.venmail.io/api/v1/checkalias',
      'https://app.venmail.io/api/v1/checkalias'
    ].freeze

    DEFAULT_TIMEOUT = 5

    def self.lookup(address, timeout: DEFAULT_TIMEOUT)
      normalized_address = address.to_s.strip.downcase
      return nil if normalized_address.blank?

      urls.each do |url|
        response = Postal::HTTP.get(url, params: { alias: normalized_address }, timeout: timeout)
        code = response && response[:code]
        yield "Available route lookup for #{normalized_address} via #{url}: #{code}" if block_given?
        next unless response && response[:code] == 200 && response[:body].present?

        begin
          parsed = JSON.parse(response[:body])
          yield "Available route lookup for #{normalized_address} via #{url}: #{parsed}" if block_given?
          return parsed
        rescue JSON::ParserError => e
          yield "Available route lookup parse failure for #{normalized_address} via #{url}: #{e.message}" if block_given?
          next
        end
      end

      nil
    rescue => e
      yield "Available route lookup request failed for #{normalized_address}: #{e.message}" if block_given?
      nil
    end

    def self.urls
      configured_url = checkalias_url_from_config
      ([configured_url].compact + DEFAULT_URLS).uniq
    end

    def self.checkalias_url_from_config
      base_url = Postal.config.general.external_api_base_url.to_s.strip
      return nil if base_url.blank?

      base_url = base_url.chomp('/')
      return base_url if base_url =~ %r{/checkalias\z}

      if base_url =~ %r{/api/v1\z}
        "#{base_url}/checkalias"
      else
        "#{base_url}/api/v1/checkalias"
      end
    end
  end
end
