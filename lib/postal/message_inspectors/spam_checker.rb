module Postal
  module MessageInspectors
    # Wrapper inspector to run the local SpamChecker for every message
    class SpamChecker < MessageInspector
      def initialize
        # SpamChecker doesn't need any config
      end
      def inspect_message(inspection)
        message = inspection.message
        raw_message = message.raw_message
        content = visible_content(raw_message)

        headers_hash = message.headers || {}
        headers_array = headers_hash.flat_map do |key, values|
          Array(values).map { |value| "#{key}: #{value}" }
        end
        subject = Array(headers_hash['subject']).last.to_s
        authenticated_from = inspection.respond_to?(:rspamd_dmarc_policy_allow?) &&
          inspection.rspamd_dmarc_policy_allow? &&
          inspection.spam_checks.none? { |check| ['ERROR', 'TIMEOUT'].include?(check.code) }

        spam_score = Postal::SpamChecker.classify_email(
          message.mail_from,
          content,
          headers_array,
          subject,
          authenticated_from
        )

        return unless spam_score

        if spam_score >= Postal::SpamChecker::HIGH_CONFIDENCE_SPAM_SCORE
          inspection.spam_checks << SpamCheck.new("V_SPAM", spam_score, "Message classified as high-confidence spam")
        elsif spam_score >= 5
          inspection.spam_checks << SpamCheck.new("V_SPAM", spam_score, "Venmail pre-classifier spam score")
        end
      rescue => e
        logger.error "Error running internal spam checker: #{e.class} (#{e.message})"
        logger.error e.backtrace[0, 5] if e.backtrace
        inspection.spam_checks << SpamCheck.new("ERROR", 0, "Error when scanning with internal spam checker")
      end

      private

      def visible_content(raw_message)
        message = Mail.read_from_string(raw_message)
        visible_parts = visible_parts_for(message)
        part = visible_parts.find { |candidate| candidate.mime_type == 'text/html' } ||
          visible_parts.find { |candidate| candidate.mime_type == 'text/plain' }

        scrub_utf8(part ? part.decoded : '')
      rescue StandardError
        safe_fallback_content(raw_message)
      end

      def scrub_utf8(content)
        content.to_s.force_encoding(Encoding::UTF_8).scrub
      end

      def attachment_disposition?(part)
        disposition = part.content_disposition.to_s
        return true if disposition.match?(/\A\s*attachment(?:\s*;|\s*\z)/i)
        return false if disposition.match?(/\A\s*inline(?:\s*;|\s*\z)/i)

        part.attachment? || filename_metadata?(part.content_type)
      end

      def visible_parts_for(part, inside_attachment = false)
        attachment = inside_attachment || attachment_disposition?(part)
        return [] if attachment

        children = part.parts
        return [part] if children.empty?

        children.flat_map { |child| visible_parts_for(child, attachment) }
      end

      def safe_fallback_content(raw_message)
        raw = raw_message.to_s
        headers, body = raw.split(/\r?\n\r?\n/, 2)
        return '' unless body
        return '' if unsafe_fallback_headers?(headers)
        return '' if unsafe_fallback_headers?(raw)

        scrub_utf8(body.byteslice(0, Postal::SpamChecker::MAX_BODY_SIZE))
      end

      def unsafe_fallback_headers?(headers)
        unfolded = headers.gsub(/\r?\n[ \t]+/, ' ')
        unfolded.each_line.any? do |line|
          line.match?(/\Acontent-type:\s*multipart\//i) ||
            line.match?(/\Acontent-disposition:\s*attachment(?:\s*;|\s*\z)/i) ||
            (line.match?(/\Acontent-type:/i) && filename_metadata?(line))
        end
      end

      def filename_metadata?(value)
        value.to_s.match?(/(?:\A|;)\s*(?:name|filename)(?:\*(?:\d+\*?)?)?\s*=/i)
      end
    end
  end
end
