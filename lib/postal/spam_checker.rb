require 'nokogiri'
require 'uri'

module Postal
  class SpamChecker
    TRUSTED_DOMAINS = [
    'gmail.com',
    'yahoo.com',
    'outlook.com',
    'hotmail.com',
    'google.com',
    'facebook.com',
    'twitter.com',
    'linkedin.com',
    'instagram.com',
    'youtube.com'
    ].freeze

    MARKETING_KEYWORDS = [
    'limited time offer',
    'discounted price',
    'exclusive deal',
    'special offer',
    'new arrival',
    'earn more',
    'best deal ever',
    'amazing opportunity',
    'extra income',
    'buy now',
    'get more',
    'buy more',
    'sell more',
    'work from home',
    'free shipping',
    'money-making',
    'huge discount',
    'clearance sale',
    'increase sales'
    ].freeze

    SPAM_PHRASES = [
    'free trial',
    'limited time offer',
    'discounted price',
    'click here to claim',
    'make money fast',
    'exclusive deal',
    'prize winner',
    'unsubscribe',
    'one-time offer',
    'best deal ever',
    'act now',
    'cash prize',
    'call now',
    'urgent',
    'money back guarantee',
    'amazing opportunity',
    'extra income',
    'buy now',
    'lowest price',
    'work from home',
    'viagra for sale',
    'lose weight fast',
    'increase your size',
    'credit card info',
    "you've won",
    'congratulations',
    'claim your prize',
    'check this out',
    'limited availability',
    'earn $$$',
    'lowest mortgage rate',
    'no obligation',
    'double your money',
    'investment opportunity',
    'million dollars',
    'free shipping',
    'apply now',
    'money-making',
    'secret formula',
    'huge discount',
    'guaranteed results',
    'instant approval',
    'satisfaction guaranteed',
    'meet singles',
    'enhance your performance',
    'cash bonus',
    'free gift',
    'easy money',
    'special promotion',
    'no risk',
    'bonus offer',
    'clearance sale',
    'great investment',
    'increase sales',
    'extra cash',
    'lowest interest rate',
    'free consultation',
    'time-limited offer',
    'stop snoring',
    'risk-free',
    '100% satisfaction',
    'incredible savings',
    'no strings attached',
    'enhance your love life',
    'lowest fees',
    'massive discount'
    ].freeze

    OFFENSIVE_PHRASES = [
    'me nude',
    'fuck me',
    'me naked',
    'go to hell',
    'asshole',
    'piece of shit',
    'motherfucker',
    'cunt',
    'dickhead',
    'bastard',
    'suck my',
    'eat shit',
    'piss off',
    'bitch',
    'shithead',
    'asswipe',
    'cock sucker',
    'son of a bitch',
    'wanker',
    'jerk off',
    'fucking idiot',
    'sick fuck',
    'stupid bitch',
    'stupid man',
    'motherfucking',
    'douchebag',
    'fuck off',
    'dumbass',
    'ass clown',
    'ass hat',
    'shit-for-brains',
    'fucking moron',
    'bitchy',
    'fucker',
    'arsehole',
    'goddamn',
    'twat',
    'cockhead',
    'dumb fuck',
    'fucking hell',
    'idiot asshole',
    'bastardized',
    'fucking bitch',
    'assholeish',
    'idiot',
    'fuckface',
    'fucking shit',
    'cuntish',
    'fucktard',
    'fuckwit',
    'dickweed',
    'assholeism',
    'fuckery',
    'cockwomble',
    'shitbag',
    'fuckstick',
    'shitfuck',
    'dickwad',
    'fucknut',
    'shitstorm',
    'motherfuck',
    'assholeishness',
    'asshat',
    'shitstain',
    'pisshead',
    'assholish',
    'fucknugget',
    'fucking asshole',
    'fucktarded',
    'arsehat',
    'fuckface',
    'assholic',
    'cockup',
    'asshatery',
    'asshatism',
    'shitfaced',
    'fucking douchebag',
    'cuntwaffle',
    'fuckball',
    'dickless',
    'fucking dick',
    'fucking motherfucker',
    'arsewipe',
    'cuntnugget',
    'fucking dickhead',
    'asswipe',
    'assclownery',
    'cockfaced',
    'arseholeism',
    'fucknuggetry',
    'shitbagging',
    'cockbag',
    'fucking wanker',
    'shitstorming',
    'fucking moronic',
    'asshatitude',
    'fuckstickery',
    'fucking shitbag',
    'assfuck',
    'fucking hellhole',
    'shitlord',
    'arsefaced',
    'fucking twat',
    'arseholery',
    'dickheaded',
    'fucking dumbass',
    'assholeishness',
    'asshattery',
    'cockwomble'
    ].freeze

    PORNOGRAPHIC_PHRASES = [
    'watch me naked',
    'check out my nude pics',
    'join me for adult fun',
    'hot and steamy action',
    'live sex show',
    'xxx video',
    'adult dating',
    'horny girls online',
    'get laid tonight',
    'free porn',
    'watch me on webcam',
    'naughty chat',
    'erotic massage',
    'pornographic content',
    'adult website',
    'nude photos',
    'sexting fun',
    'sexy singles in your area',
    'naked girls',
    'sexy videos',
    'porn star experience',
    'hot babes waiting for you',
    'online sex',
    'sex chat',
    'erotic videos',
    'adult entertainment',
    'dirty talk',
    'explicit content',
    'sexy cam girls',
    'naughty girls',
    'erotic chat',
    'webcam models',
    'live nude show',
    'sexting buddy',
    'adult hookup',
    'sexting chat',
    'online dating for adults',
    'sexy webcam models',
    'adult fun',
    'casual sex',
    'sexy chat',
    'naked women',
    'live sex chat',
    'adult webcam',
    'xxx movies',
    'erotic photos',
    'find a fuck buddy',
    'nude chat',
    'dirty chat',
    'naughty chat room',
    'online porn',
    'adult chat',
    'sexy hookups',
    'horny women',
    'sexting partner',
    'naked chat',
    'adult dating site',
    'nude chat room',
    'erotic stories',
    'online sex chat',
    'adult video chat',
    'horny singles',
    'sexting app',
    'adult content',
    'find local sex',
    'sexy talk',
    'naughty video chat',
    'adult hookup sites',
    'online adult dating',
    'sexy messaging',
    'erotic chat room',
    'nude dating',
    'sex chat room',
    'adult video',
    'porn site',
    'adult webcams',
    'naughty dating',
    'adult personals',
    'sex cam',
    'xxx chat',
    'naked chat room',
    'sexy hookup',
    'erotic chat sites',
    'live nude cam',
    'adult dating app',
    'nude cam',
    'adult video site',
    'erotic webcam',
    'porn chat',
    'sexting website',
    'nude dating site',
    'adult friend finder',
    'xxx chat room',
    'live porn',
    'sexy video chat',
    'adult cam',
    'erotic video chat',
    'nude webcams',
    'find sex online',
    'hot chat',
    'adult dating apps',
    'sex video chat',
    'nude webcam',
    'adult dating sites',
    'erotic messaging',
    'xxx webcam',
    'live adult chat',
    'nude webcam chat',
    'adult chat sites',
    'sex video site',
    'sexy video chat rooms',
    'live sex shows',
    'adult chat rooms',
    'erotic webcam chat',
    'pornographic chat',
    'adult sex chat',
    'live porn chat',
    'nude video chat',
    'adult hookup site',
    'erotic webcam sites',
    'online porn chat',
    'adult web chat',
    'live nude cams',
    'adult cam chat',
    'erotic video chat rooms',
    'pornographic webcams',
    'live porn cams',
    'nude cam chat',
    'adult video chat rooms',
    'pornographic video chat',
    'live nude chat',
    'adult live chat',
    'erotic video chat sites',
    'adult webcam chat',
    'pornographic video chat rooms',
    'live porn shows',
    'adult video chat sites',
    'erotic webcam chat rooms',
    'live nude cam chat',
    'adult sex chat rooms'
    ].freeze

    FINANCE_REGEX = /\b(?: 
    ambassador | 
    minister | 
    president | 
    prince | 
    director | 
    royal | 
    am\s*offering\s*you |
    diplomatic | 
    fund\s*notification | 
    private\s*email | 
    fund\s*beneficiary | 
    as\s*a\s*beneficiary | 
    confiscation | 
    compensate | 
    atm\s*card | 
    introducing\s*myself | 
    his\s*position | 
    scams? | 
    foreign\s*mission | 
    deliver\s*your\s*atm\s*card | 
    registration\s*fee | 
    legitimacy | 
    dubious | 
    payment\s*information | 
    immediate\s*attention | 
    western\s*union | 
    money\s*gram | 
    deposit | 
    deceased | 
    bereaved | 
    lottery | 
    winner | 
    claim\s*prize | 
    bank\s*transfer | 
    confidential | 
    personal\s*account | 
    personal\s*bank\s*account | 
    verify\s*your\s*account | 
    free\s*gift | 
    \$\d+(?:,\d{3})*(?:\.\d{2})?\s*u\.s\.\s*dollars | 
    atm\s*master\s*card | 
    million\s*dollars | 
    immediate\s*response | 
    personal\s*assistance | 
    overseas\s*account |
    mineral\s*resources |
    government\s*approval | 
    final\s*notice | 
    award\s*winner | 
    legal\s*claim | 
    cash\s*prize | 
    benefactor | 
    fortune | 
    inherit | 
    heritage | 
    transfer\s*of\s*funds | 
    investment\s*funds | 
    agreement\s*with\s*me | 
    investment\s*opportunity | 
    secure\s*transaction | 
    next\s*of\s*kin 
    )\b/ix.freeze

    FINANCE_REGEX1 = /\b(?: 
    bonus | 
    charity | 
    transaction | 
    government | 
    united\s*nation | 
    related\s*to | 
    reward | 
    donation | 
    trust | 
    transfer | 
    approval | 
    delivery | 
    bitcoin\s*address | 
    executive | 
    guarantee | 
    reimbursement | 
    urgent 
    )\b/ix.freeze

    EMAIL_REGEX = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i.freeze

    class << self
      def extract_links(content)
        links = {}
        document = Nokogiri::HTML(content)
        document.css('a').each do |link|
          href = link['href']
          label = link.text.strip
          next if href.nil?

          links[href] ||= []
          links[href] << label
        end
        links
      rescue => e
        # Handle Nokogiri errors gracefully
        puts "Error parsing HTML content: #{e.message}"
        {}
      end

      def check_for_spam_links(links)
        return 0 unless links.is_a?(Hash)

        trusted_domains_pattern = TRUSTED_DOMAINS.map { |domain| Regexp.escape(domain) }.join('|')
        trusted_domains_regex = /^(https?:\/\/)?(www\.)?(#{trusted_domains_pattern}|([a-z0-9-]+\.)?#{trusted_domains_pattern})$/i

        spam_links_count = 0
        links.each do |href, labels|
          next if trusted_domains_regex.match?(href)
        
          if labels.uniq.size > 1 && !href.start_with?('mailto:')
            spam_links_count += 1
          end
        end
          
        spam_links_count
      end

      def check_for_mismatched_sender(sender_email, links)
        return 0 unless sender_email =~ EMAIL_REGEX && links.is_a?(Hash)

        sender_domain = sender_email.split('@').last
        common_domains = %w[gmail.com yahoo.com outlook.com hotmail.com]
        return 0 if common_domains.include?(sender_domain)

        mismatched_count = 0

        links.each_key do |href|
          next if href.start_with?('mailto:')
          mismatched_count += 1 unless href.include?(sender_domain)
        end

        mismatched_count
      end

      def classify_email(sender_email, parsed)
        links = extract_links(parsed)
        bad_links = check_for_spam_links(links)
        mismatched = check_for_mismatched_sender(sender_email, links)

        parsed = strip_html(parsed)
        body_lower = parsed.downcase

        gibberish_pattern = /(?<![aeiouy])[aeiouy]{3,}(?![aeiouy])|(?<![bcdfghjklmnpqrstvwxyz])[bcdfghjklmnpqrstvwxyz]{3,}(?![bcdfghjklmnpqrstvwxyz])/
        contains_gibberish = body_lower.match?(gibberish_pattern)

        marketing_count = count_keywords(MARKETING_KEYWORDS, body_lower)
        spam_count = count_keywords(SPAM_PHRASES, body_lower)
        offensive_count = count_keywords(OFFENSIVE_PHRASES, body_lower)
        pornographic_count = count_keywords(PORNOGRAPHIC_PHRASES, body_lower)

        finance_count = body_lower.scan(FINANCE_REGEX).size
        finance_count1 = body_lower.scan(FINANCE_REGEX1).size

        score = 0
        score += 2 * bad_links
        score += 0.5 * mismatched
        score += (contains_gibberish ? 1 : 0)
        score += 0.5 * marketing_count
        score += 1 * spam_count
        score += 1.5 * offensive_count
        score += 2 * pornographic_count
        score += 1.5 * finance_count
        score += 1 * finance_count1

        [[score, 1].max, 10].min
      end

      private

      def strip_html(content)
        Nokogiri::HTML(content).text
      end

      def count_keywords(keywords, body)
        keywords.sum { |keyword| body.scan(keyword).size }
      end
    end
  end
end
