module Postal
  module VVS
    class Signer

      def self.generate_nonce
        SecureRandom.hex(16)
      end

      def self.compute_content_hash(canonical_body)
        digest = Digest::SHA256.digest(canonical_body)
        "sha256=#{Base64.urlsafe_encode64(digest, padding: false)}"
      end

      # Sign a message and return a hash of VVS header name/value pairs
      def self.sign(agent_key, from:, to:, subject:, date:, body:)
        canonical_body = Canonicalizer.canonicalize_body(body)
        content_hash = compute_content_hash(canonical_body)
        nonce = generate_nonce
        timestamp = Time.now.utc.to_i.to_s
        canonical_headers = Canonicalizer.canonicalize_headers(
          from: from, to: to, subject: subject, date: date
        )
        payload = Canonicalizer.build_canonical_payload(
          agent_key.agent_id, timestamp, nonce, content_hash, canonical_headers
        )

        signature_bytes = agent_key.sign(payload)
        signature = Base64.urlsafe_encode64(signature_bytes, padding: false)
        verify_methods = Postal.config.vvs&.default_verify_methods || 'well-known,dns'

        {
          'X-Venmail-Agent' => agent_key.agent_id,
          'X-Venmail-Signature' => signature,
          'X-Venmail-Algorithm' => 'ed25519',
          'X-Venmail-Timestamp' => timestamp,
          'X-Venmail-Nonce' => nonce,
          'X-Venmail-Content-Hash' => content_hash,
          'X-Venmail-Verify-Method' => verify_methods
        }
      end

    end
  end
end
