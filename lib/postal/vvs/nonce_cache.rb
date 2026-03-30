module Postal
  module VVS
    class NonceCache

      SEEN = {}

      def self.seen?(nonce)
        cleanup!
        SEEN.key?(nonce)
      end

      def self.record!(nonce, window: 3600)
        SEEN[nonce] = Time.now.to_i + window
      end

      def self.cleanup!
        now = Time.now.to_i
        SEEN.delete_if { |_, expires| expires < now }
      end

      def self.clear!
        SEEN.clear
      end

    end
  end
end
