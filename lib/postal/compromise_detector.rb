require 'cgi'

module Postal
  class CompromiseDetector
    EXTRA_CODES = %w[
      COMPROMISE_PORN
      COMPROMISE_EMPTY
      COMPROMISE_GIBBERISH
      COMPROMISE_BASE64_BLOB
      COMPROMISE_SOCIAL_SECURITY_SPOOF
    ].freeze

    DEFAULT_STRONG_CODES = %w[COMPROMISE_BITCOIN COMPROMISE_BLACKMAIL COMPROMISE_LEGAL_BENEFICIARY].freeze

    STRONG_CODES = DEFAULT_STRONG_CODES
    ALL_CODES = (DEFAULT_STRONG_CODES + EXTRA_CODES).freeze

    def self.strong_codes
      cfg = (Postal.config.general.compromise.strong_codes rescue nil)
      codes = Array(cfg).map(&:to_s).map(&:strip).reject(&:empty?)
      codes.any? ? codes : DEFAULT_STRONG_CODES
    end

    def self.all_codes
      (strong_codes + EXTRA_CODES).uniq
    end

    def self.countable_codes
      cfg = (Postal.config.general.compromise.countable_codes rescue nil)
      codes = Array(cfg).map(&:to_s).map(&:strip).reject(&:empty?)
      return codes if codes.any?

      (strong_codes + %w[COMPROMISE_BASE64_BLOB COMPROMISE_SOCIAL_SECURITY_SPOOF]).uniq
    end

    Result = Struct.new(:codes, :descriptions) do
      def suspicious?
        codes.any?
      end

      def strong?
        (codes & CompromiseDetector.strong_codes).any?
      end
    end

    def analyze(message)
      text = extract_text(message)
      html = message.html_body rescue nil
      codes = []
      descs = []

      if text.strip.empty?
        unless image_rich_html?(html)
          codes << 'COMPROMISE_EMPTY'
          descs << 'Empty body'
        end
      end

      min_text_len = (config_value(:gibberish, :min_text_length) || 50).to_i
      skip_gibberish = image_rich_html?(html) && text.strip.size < min_text_len

      unless skip_gibberish
        nonword_max = (config_value(:gibberish, :nonword_ratio_max) || 0.6).to_f
        letter_ratio_min = (config_value(:gibberish, :letter_ratio_min) || 0.2).to_f
        letter_ratio = text.scan(/[\p{L}\p{N}]/).size.to_f / [text.size, 1].max
        nonword_ratio = text.gsub(/[\p{L}\p{N}\s]/, '').size.to_f / [text.size, 1].max
        if nonword_ratio > nonword_max && letter_ratio < letter_ratio_min
          codes << 'COMPROMISE_GIBBERISH'
          descs << 'Unreadable/gibberish content'
        end
      end

      bitcoin_pattern = /\b(bc1[0-9a-z]{25,87}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b/i
      bitcoin_match = text.match(bitcoin_pattern)
      bitcoin_detected = false
      if bitcoin_match
        match_pos = bitcoin_match.begin(0)
        match_text = bitcoin_match[0]
        context_before = text[[0, match_pos - 50].max, 50].to_s
        context_after = text[match_pos + match_text.length, 20].to_s
        url_indicators = %r{(https?://|www\.|\.(com|org|net|io|meet)/|@[a-z0-9])}
        transaction_pattern = %r{(tx|transaction|ref|reference|id|meeting|meet)[\s:=#-]}i
        is_url_context = context_before =~ url_indicators || context_after =~ %r{(/|@|\.(com|org|net|io))}
        is_transaction_id = context_before =~ transaction_pattern || context_after =~ transaction_pattern
        bitcoin_detected = !(is_url_context || is_transaction_id)
      end
      if bitcoin_detected
        codes << 'COMPROMISE_BITCOIN'
        descs << 'Bitcoin address detected'
      end

      porn_words = (Postal.config.general.compromise.porn_words rescue nil) || %w[sex porn xxx nude anal blowjob escort camgirl hentai shemale incest]
      downcased = text.downcase
      porn_hits = porn_words.count { |w| downcased =~ /\b#{Regexp.escape(w.to_s.downcase)}\b/ }
      porn_threshold = (config_value(:porn, :hits_threshold) || 3).to_i
      if porn_hits >= porn_threshold
        codes << 'COMPROMISE_PORN'
        descs << 'Pornographic slang density'
      end

      government_claim_patterns = [
        /social\s+security/i,
        /ssa[-\s]?1099/i,
        /benefit\s+statement/i,
        /ssa[-\s]?1099[\s\-]?form/i,
        /social\s+security\s+administration/i,
        /medicare\s+(deductions?|premiums?)/i,
        /medicaid/i,
        /official\s+(statement|notice|document)/i,
        /benefits?\s+(paid|pay(ment)?s?|available|eligib(le|ility))/i,
        /\b1099[\-\s]?(ssa|gov)\b/i,
        /\btax\b.+(ssa|irs|treasury|refund|rebate|payment|stimulus)/i,
        /internal\s+revenue\s+service/i,
        /\birs\b/i,
        /tax\s+(refund|rebate)/i,
        /stimulus\s+payment/i,
        /treasury\s+department/i,
        /unemployment\s+benefits?/i,
        /department\s+of\s+labor/i,
        /federal\s+(grant|assistance|relief|payment)/i,
        /government\s+(assistance|grant|relief|benefit|payment)/i,
        /call\s+1[-\s]?(800|888|877|866|855|844|833)[-\s]?\d{3}[-\s]?\d{4}/i
      ]
      if government_claim_patterns.any? { |rx| text =~ rx }
        sender_domain = extract_sender_domain(message)
        unless authoritative_government_domain?(sender_domain)
          codes << 'COMPROMISE_SOCIAL_SECURITY_SPOOF'
          descs << 'Government benefit/authority themed content from non-authoritative sender domain'
        end
      end

      if legal_beneficiary_scam?(text)
        codes << 'COMPROMISE_LEGAL_BENEFICIARY'
        descs << 'Legal/estate beneficiary advance-fee scam pattern'
      end

      blackmail_phrases = (Postal.config.general.compromise.blackmail_phrases rescue nil) || [
        'blackmail', 'i hacked', 'i have hacked', 'recorded you', 'send to (all )?your contacts?'
      ]
      payment_phrases = (Postal.config.general.compromise.blackmail_payment_phrases rescue nil) || [
        'pay\s*bitcoin', 'send\s*bitcoin'
      ]
      deadline_phrases = (Postal.config.general.compromise.blackmail_deadline_phrases rescue nil) || [
        'within\s*\d+\s*hours'
      ]

      blackmail_hit = blackmail_phrases.any? { |kw| downcased =~ /#{kw}/i }
      payment_hit = bitcoin_detected || payment_phrases.any? { |kw| downcased =~ /#{kw}/i }
      deadline_hit = deadline_phrases.any? { |kw| downcased =~ /#{kw}/i }

      if blackmail_hit && payment_hit
        codes << 'COMPROMISE_BLACKMAIL'
        descs << 'Extortion/blackmail phrasing'
      end

      min_blob_len = (config_value(:base64, :min_length) || 200).to_i
      max_blob_lines = (config_value(:base64, :max_lines) || 8).to_i
      if text.lines.count <= max_blob_lines
        if (m = text.match(/\b([A-Za-z0-9+\/]{#{min_blob_len},}={0,2})\b/))
          blob = m[1]
          if blob.include?('+') || blob.include?('/') || blob.include?('=')
            match_pos = m.begin(1)
            context_before = text[[0, match_pos - 30].max, 30].to_s
            url_indicators = %r{(https?://|www\.|api[_-]?key|token|secret|authorization|bearer|data:)}
            unless context_before =~ url_indicators
              codes << 'COMPROMISE_BASE64_BLOB'
              descs << 'Large base64-like blob'
            end
          end
        end
      end

      Result.new(codes.uniq, descs)
    end

    private

    def image_rich_html?(html)
      body = html.to_s
      return false if body.strip.empty?
      return false unless body =~ /<img\b/i

      min_len = (config_value(:empty, :min_html_length_for_image_only) || 200).to_i
      body.length >= min_len
    end

    def extract_text(message)
      body = message.plain_body.to_s
      if body.strip.empty?
        html = message.html_body rescue nil
        body = html.gsub(/<[^>]+>/, ' ')
        body = CGI.unescapeHTML(body) rescue body
      end
      body = body.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') rescue body
      body.to_s[0, 20000]
    end

    def config_value(section, key)
      Postal.config.general.compromise.send(section).send(key) rescue nil
    end

    def extract_sender_domain(message)
      address = message.mail_from || message.from rescue nil
      raw = address.to_s
      domain = raw[/@([^>\s;]+)/, 1] || raw.split('@').last
      domain.to_s.downcase.gsub(/[^\w\.-]/, '')
    end

    def legal_beneficiary_scam?(text)
      downcased = text.to_s.downcase
      estate_hit = downcased =~ /\b(beneficiar(?:y|ies)|deceased|estate|probate|next\s+of\s+kin|inheritance|entitlement|asset\s+distribution)\b/
      authority_hit = downcased =~ /\b(legal\s+advisou?r|solicitors?|attorney[-\s]client|senior\s+partner|confidential|gdpr)\b/
      action_hit = downcased =~ /\b(confirm\s+your\s+relationship|declare\s+your\s+interest|pursuing\s+entitlement|failure\s+to\s+respond|reply\s+to)\b/

      estate_hit && authority_hit && action_hit
    end

    def authoritative_government_domain?(domain)
      return false if domain.blank?
      # Accept .gov, .gov.xx, .gov.xx.xx, and .mil variants only (avoid foo.gov.evil.com)
      !!(domain =~ /\A([a-z0-9-]+\.)*(gov|mil)(\.[a-z]{2,3}){0,2}\z/i)
    end
  end
end
