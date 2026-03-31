module Postal
  module VVS
    class Verifier

      TIMESTAMP_WINDOW = 3600

      # Full verification algorithm per VVS-1 §7
      # Returns: :verified, :partial, :failed, or :unknown
      def self.verify(headers_hash, raw_body)
        # 1. Extract VVS headers. If none → :unknown
        agent_id = headers_hash['X-Venmail-Agent']
        return :unknown unless agent_id

        signature = headers_hash['X-Venmail-Signature']
        algorithm = headers_hash['X-Venmail-Algorithm']
        timestamp_str = headers_hash['X-Venmail-Timestamp']
        nonce = headers_hash['X-Venmail-Nonce']
        content_hash_header = headers_hash['X-Venmail-Content-Hash']
        verify_methods = (headers_hash['X-Venmail-Verify-Method'] || '').split(',').map(&:strip)
        embedded_key = headers_hash['X-Venmail-Public-Key']

        # 2. Validate required fields
        return :failed unless signature && algorithm && timestamp_str && nonce && content_hash_header
        return :failed unless algorithm == 'ed25519'

        # 3. Validate timestamp within replay window
        window = Postal.config.vvs&.timestamp_window || TIMESTAMP_WINDOW
        timestamp = timestamp_str.to_i
        return :failed if (Time.now.utc.to_i - timestamp).abs > window

        # 4. Parse agent ID
        at_index = agent_id.index('@')
        return :failed unless at_index && at_index > 0
        agent_name = agent_id[0...at_index]
        domain = agent_id[(at_index + 1)..]
        return :failed if domain.nil? || domain.empty?

        # 5. Check nonce if enabled
        if Postal.config.vvs&.nonce_check
          return :failed if NonceCache.seen?(nonce)
          NonceCache.record!(nonce, window: window)
        end

        # 6. Verify content hash
        canonical_body = Canonicalizer.canonicalize_body(raw_body)
        computed_hash = Signer.compute_content_hash(canonical_body)
        return :failed unless computed_hash == content_hash_header

        # 7. Build canonical payload
        from = headers_hash['From'] || ''
        to = headers_hash['To'] || ''
        subject = headers_hash['Subject'] || ''
        date = headers_hash['Date'] || ''
        canonical_headers = Canonicalizer.canonicalize_headers(
          from: from, to: to, subject: subject, date: date
        )
        payload = Canonicalizer.build_canonical_payload(
          agent_id, timestamp_str, nonce, computed_hash, canonical_headers
        )

        signature_bytes = Base64.urlsafe_decode64(signature)

        # 8. Resolve key and verify signature for each method
        verify_methods.each do |method|
          begin
            resolved = KeyResolver.resolve(agent_name, domain, method, embedded_key: embedded_key)
            next unless resolved
            return :failed if resolved[:status] != 'active'

            verify_key = Ed25519::VerifyKey.new(Base64.urlsafe_decode64(resolved[:key]))
            verify_key.verify(signature_bytes, payload)

            # Verification succeeded
            return method == 'embedded' ? :partial : :verified
          rescue Ed25519::VerifyError
            next
          rescue => e
            next
          end
        end

        # 9. All methods exhausted
        :failed
      end

    end
  end
end
