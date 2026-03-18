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

        headers_hash = message.headers || {}
        headers_array = headers_hash.flat_map do |key, values|
          Array(values).map { |value| "#{key}: #{value}" }
        end
        subject = Array(headers_hash['subject']).last.to_s

        spam_score = Postal::SpamChecker.classify_email(
          message.mail_from,
          raw_message,
          headers_array,
          subject
        )

        return unless spam_score

        if spam_score > 20
          inspection.spam_checks << SpamCheck.new("V_SPAM", spam_score, "Message classified as spam")
        elsif spam_score > 5
          adjusted_score = spam_score / 2.0
          inspection.spam_checks << SpamCheck.new("V_SPAM", adjusted_score, "Venmail pre-classifier spam score")
        end
      rescue => e
        logger.error "Error running internal spam checker: #{e.class} (#{e.message})"
        logger.error e.backtrace[0, 5] if e.backtrace
        inspection.spam_checks << SpamCheck.new("ERROR", 0, "Error when scanning with internal spam checker")
      end
    end
  end
end
