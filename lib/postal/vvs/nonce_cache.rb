module Postal
  module VVS
    class NonceCache

      MUTEX = Mutex.new
      SEEN = {}
      MAX_SIZE = 100_000

      def self.seen?(nonce)
        MUTEX.synchronize do
          cleanup!
          SEEN.key?(nonce)
        end
      end

      def self.record!(nonce, window: 3600)
        MUTEX.synchronize do
          # Evict oldest entries if at capacity
          if SEEN.size >= MAX_SIZE
            oldest_keys = SEEN.sort_by { |_, v| v }.first(SEEN.size / 4).map(&:first)
            oldest_keys.each { |k| SEEN.delete(k) }
          end
          SEEN[nonce] = Time.now.to_i + window
        end
      end

      def self.cleanup!
        now = Time.now.to_i
        SEEN.delete_if { |_, expires| expires < now }
      end

      def self.clear!
        MUTEX.synchronize { SEEN.clear }
      end

    end
  end
end
