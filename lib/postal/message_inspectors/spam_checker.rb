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
        part = if message.multipart?
          visible_parts = message.all_parts.reject { |candidate| attachment_disposition?(candidate) }
          visible_parts.find { |candidate| candidate.mime_type == 'text/html' } ||
            visible_parts.find { |candidate| candidate.mime_type == 'text/plain' }
        elsif !attachment_disposition?(message)
          message
        end

        scrub_utf8(part ? part.decoded : '')
      rescue StandardError
        safe_fallback_content(raw_message)
      end

      def scrub_utf8(content)
        content.to_s.force_encoding(Encoding::UTF_8).scrub
      end

      def attachment_disposition?(part)
        part.content_disposition.to_s.match?(/\A\s*attachment(?:\s*;|\s*\z)/i)
      end

      def safe_fallback_content(raw_message)
        raw = raw_message.to_s
        headers, body = raw.split(/\r?\n\r?\n/, 2)
        return '' unless body
        return '' if headers.each_line.any? { |line| line.match?(/\Acontent-type:\s*multipart\//i) }
        return '' if headers.each_line.any? { |line| line.match?(/\Acontent-disposition:\s*attachment(?:\s*;|\s*\z)/i) }
        return '' if raw.each_line.any? { |line| line.match?(/\Acontent-disposition:\s*attachment(?:\s*;|\s*\z)/i) }

        scrub_utf8(body.byteslice(0, Postal::SpamChecker::MAX_BODY_SIZE))
      end
    end
  end
end
