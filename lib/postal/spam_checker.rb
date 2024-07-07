require 'nokogiri'
require 'uri'

module Postal
  class SpamChecker
    TRUSTED_DOMAINS = [
    'googlemail.com',
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

      def log(text)
        Postal.logger_for(:http_sender).info("[#{@log_id}] #{text}")
      end

      def check_for_spam_links(links)
        return 0 unless links.is_a?(Hash)

        trusted_domains_pattern = TRUSTED_DOMAINS.map { |domain| Regexp.escape(domain) }.join('|')
        trusted_domains_regex = /^(https?:\/\/)?(?:[^\/]+\.)?(#{trusted_domains_pattern})(\/|$)/i

        spam_file_extensions = /\.(php|cgi|html)\z/i

        spam_links_count = 0
        links.each do |href, labels|
          next if trusted_domains_regex.match?(href)
          next if href.nil? || href.empty?
          next unless href.is_a?(String)
          next if href.start_with?('mailto:')

          if labels.uniq.size > 1
            if href.match?(spam_file_extensions)
              spam_links_count += labels.size
            else
              spam_links_count += 1
            end
          end
        end
        log "#{spam_links_count} spam links found"

        spam_links_count
      end

      def extract_base_domain(domain)
        # Extract the base domain using regex
        domain.match(/(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/).to_s
      end
      
      def extract_href_base_domain(href)
        # Extracting base domain from href using regex
        href.match(/^(?:https?:\/\/)?(?:[^@\/\n]+@)?(?:www\.)?([^:\/?\n]+)/im)[1] rescue nil
      end
      
      def check_for_mismatched_sender(sender_email, links)
        return 0 unless sender_email =~ EMAIL_REGEX && links.is_a?(Hash)
        
        sender_domain = sender_email.split('@').last
        sender_base_domain = extract_base_domain(sender_domain)
        common_domains = %w[gmail.com googlemail.com yahoo.com outlook.com hotmail.com]
        return 0 if common_domains.include?(sender_domain)
        
        tracking_domains = %w[
          list-manage.com
          mcsv.net
          rs6.net
          sendgrid.net
          sendgrid.com
          sgizmo.com
          mktoresp.com
          marketo.com
          marketo.net
          hubspot.com
          hubspotemail.net
          cmail1.com
          cmail2.com
          cmail20.com
          createsend.com
          aweber.com
          aweber.net
          getresponse.com
          getresponse.net
          mailgun.org
          mailgun.com
          infusionsoft.com
          acems1.com
          e2ma.net
          e2ma.com
          salesforce.com
          salesforceiq.com
          dripemail2.com
          drip.com
          pardot.com
          pardot.net
          klaviyo.com
          klclick.com
          convertkit-mail.com
          convertkit.com
          mailchimp.com
          mailchimpapp.com
          mandrillapp.com
          mandrill.com
          amazonaws.com
          sparkpost.com
          sparkpostmail.com
          bnc.lt
          omkt.co
          relay.bm
          feedblitz.com
          benchmarkemail.com
          email.benchmarkemail.com
          emailcontact.com
          envoydispatch.com
          mailerlite.com
          mltrk.io
          mlsend.com
          ontraport.com
          ontramail.com
          protonmail.com
          protonmail.ch
          sendinblue.com
          smtp.com
          tracking.urbndata.com
          us2.list-manage.com
          us10.list-manage.com
        ]
        
        subdomain_patterns = %w[
          click
          track
        ]
        
        # Create regex pattern for tracking domains and subdomain patterns
        tracking_domains_regex = Regexp.new(tracking_domains.map { |domain| Regexp.escape(domain) }.join('|'))
        subdomain_patterns_regex = Regexp.new(subdomain_patterns.map { |subdomain| "#{Regexp.escape(subdomain)}\\." }.join('|'))
        
        # Combined regex for matching full domains or subdomains with specific patterns
        tracking_regex = /^(https?:\/\/)?(#{subdomain_patterns_regex})*[^\/]+\.(#{tracking_domains_regex})(\/|$)/i
        
        # Regex to match any domain using the specified subdomain patterns
        subdomain_only_regex = /^(https?:\/\/)?(#{subdomain_patterns_regex})/i
        
        trusted_domains_pattern = TRUSTED_DOMAINS.map { |domain| Regexp.escape(domain) }.join('|')
        sender_domain_regex = /^(https?:\/\/)?([^\/]+\.)*#{Regexp.escape(sender_domain)}(\/|$)/i
        trusted_domains_regex = /^(https?:\/\/)?([^\/]+\.)*(#{trusted_domains_pattern})(\/|$)/i
        
        mismatched_count = 0
        
        links.each_key do |href|
          next if href.nil? || href.empty?
          next unless href.is_a?(String)
          next if href.start_with?('mailto:')
          next if href =~ tracking_regex || href =~ subdomain_only_regex
          next if href =~ tracking_domains_regex
        
          link_base_domain = extract_href_base_domain(href)
        
          # Compare base domains and skip if they match
          mismatched_count += 1 unless link_base_domain && link_base_domain.include?(sender_base_domain)
        end
        log "#{mismatched_count} mismatched links found"
        
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
        log "#{finance_count} finance count"
        log "#{marketing_count} marketing count"
        log "#{finance_count} offsensive count"
        log "#{finance_count1} finance1 count"

        mismatchScore = (bad_links > 0 ? 0.5 : 0) * mismatched
        score = 0
        score += 1.5 * bad_links
        score += (mismatchScore > 4 ? 4 : mismatchScore)
        score += (contains_gibberish ? 1 : 0)
        score += 0.5 * marketing_count
        score += 1 * spam_count
        score += 1.5 * offensive_count
        score += 2 * pornographic_count
        score += 1.5 * finance_count
        score += (finance_count > 0 ? 0.5 : 0) * finance_count1

        [[score, 1].max, 20].min
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
