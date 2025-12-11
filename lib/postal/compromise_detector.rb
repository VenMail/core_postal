module Postal
  class CompromiseDetector
    STRONG_CODES = %w[COMPROMISE_BITCOIN COMPROMISE_BLACKMAIL].freeze
    ALL_CODES = (
      STRONG_CODES + %w[
        COMPROMISE_PORN
        COMPROMISE_EMPTY
        COMPROMISE_GIBBERISH
        COMPROMISE_BASE64_BLOB
      ]
    ).freeze

    Result = Struct.new(:codes, :descriptions) do
      def suspicious?
        codes.any?
      end

      def strong?
        (codes & CompromiseDetector::STRONG_CODES).any?
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
        ascii_min = (config_value(:gibberish, :ascii_ratio_min) || 0.6).to_f
        nonword_max = (config_value(:gibberish, :nonword_ratio_max) || 0.6).to_f
        ascii_ratio = text.bytes.count { |b| b < 128 }.to_f / [text.bytesize, 1].max
        nonword_ratio = text.gsub(/[A-Za-z0-9\s]/, '').size.to_f / [text.size, 1].max
        if ascii_ratio < ascii_min || nonword_ratio > nonword_max
          codes << 'COMPROMISE_GIBBERISH'
          descs << 'Unreadable/gibberish content'
        end
      end

      if text =~ /(bc1[0-9a-z]{25,87}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})/i
        codes << 'COMPROMISE_BITCOIN'
        descs << 'Bitcoin address detected'
      end

      porn_words = (Postal.config.general.compromise.porn_words rescue nil) || %w[sex porn xxx nude anal blowjob escort camgirl hentai shemale incest]
      porn_hits = porn_words.count { |w| text.downcase.include?(w) }
      porn_threshold = (config_value(:porn, :hits_threshold) || 3).to_i
      if porn_hits >= porn_threshold
        codes << 'COMPROMISE_PORN'
        descs << 'Pornographic slang density'
      end

      blackmail_keywords = (Postal.config.general.compromise.blackmail_keywords rescue nil) || [
        'blackmail', 'i hacked', 'pay\s*bitcoin', 'send to your contacts', 'recorded you', 'within \d+ hours'
      ]
      if blackmail_keywords.any? { |kw| text.downcase =~ /#{kw}/i }
        codes << 'COMPROMISE_BLACKMAIL'
        descs << 'Extortion/blackmail phrasing'
      end

      min_blob_len = (config_value(:base64, :min_length) || 40).to_i
      if text =~ /\b[A-Za-z0-9+\/]{#{min_blob_len},}={0,2}\b/ && text.lines.count <= 5
        codes << 'COMPROMISE_BASE64_BLOB'
        descs << 'Large base64-like blob'
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
      body = message.plain_body || ''
      if body.strip.empty?
        html = message.html_body || ''
        body = html.gsub(/<[^>]+>/, ' ')
      end
      body = body.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') rescue body
      body.to_s[0, 20000]
    end

    def config_value(section, key)
      Postal.config.general.compromise.send(section).send(key) rescue nil
    end
  end
end
