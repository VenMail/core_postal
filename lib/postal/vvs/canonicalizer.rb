module Postal
  module VVS
    class Canonicalizer

      # VVS-1 §4.1 — Body canonicalization
      # - Encode as UTF-8
      # - Normalize all line endings to \n (LF)
      # - Strip trailing whitespace from each line
      # - Do NOT strip leading whitespace
      def self.canonicalize_body(raw_body)
        body = raw_body.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
        body = body.gsub("\r\n", "\n").gsub("\r", "\n")
        lines = body.split("\n", -1)
        lines.map { |line| line.rstrip }.join("\n")
      end

      # VVS-1 §4.2 — Header canonicalization
      # Take from, to, subject, date headers
      # - Lowercase all field names
      # - Strip leading/trailing whitespace from values
      # - Fold multi-line values: replace \r\n <ws> with single space
      # - Sort fields alphabetically by name
      # - Join as {name}:{value} separated by \n
      def self.canonicalize_headers(from:, to:, subject:, date:)
        fields = {
          'date' => date.to_s,
          'from' => from.to_s,
          'subject' => subject.to_s,
          'to' => to.to_s
        }
        fields.sort.map do |name, value|
          value = value.gsub(/\r?\n[\t ]+/, ' ').strip
          "#{name}:#{value}"
        end.join("\n")
      end

      # VVS-1 §4.2 — Build canonical signing payload
      def self.build_canonical_payload(agent_id, timestamp, nonce, content_hash, canonical_headers)
        "#{agent_id}\n#{timestamp}\n#{nonce}\n#{content_hash}\n#{canonical_headers}\n"
      end

    end
  end
end
