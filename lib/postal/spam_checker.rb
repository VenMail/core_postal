require 'nokogiri'
require 'uri'

module Postal
  class SpamChecker
    TRUSTED_DOMAINS = [
    'googlemail.com',
    'gmail.com',
    'yahoo.com',
    'outlook.com',
    'live.com',
    'hotmail.com',
    'google.com',
    'facebook.com',
    'fb.me',
    'twitter.com',
    'x.com',
    't.co',
    'linkedin.com',
    'instagram.com',
    'instagr.am',
    'youtube.com',
    'youtu.be'
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
    prince | 
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
    a\s*fortune | 
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
    director | 
    ambassador | 
    minister | 
    president | 
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

    # Restricted domains that should not send priority/urgent emails
    RESTRICTED_DOMAINS = [
      'venmail.io',
      'venia.cloud', 
      'bammby.com'
    ].freeze

    # Suspicious confirmation phrases
    SUSPICIOUS_CONFIRMATION_PHRASES = [
      'shipment confirmation',
      'shipping confirmed',
      'money received',
      'wallet updated',
      'health check',
      'investment opportunity',
      'payment received',
      'account verification',
      'address update required',
      'delivery confirmation',
      'package dispatched',
      'order confirmed',
      'payment processed',
      'transaction completed'
    ].freeze

    # Priority indicators that should be blocked from restricted domains
    PRIORITY_INDICATORS = [
      'x-priority: 1',
      'priority: urgent',
      'importance: high',
      'urgent',
      'high priority',
      'immediate action required',
      'act now'
    ].freeze

    # Company name patterns for domain matching
    COMPANY_KEYWORDS = [
      'global',
      'shipping',
      'company',
      'inc',
      'corp',
      'corporation',
      'llc',
      'limited',
      'services',
      'express',
      'delivery',
      'courier',
      'logistics',
      'freight',
      'transport'
    ].freeze

    class << self
      attr_accessor :header_tracker
      
      def initialize_tracker
        @header_tracker ||= {}
      end
      
      def track_header_fingerprint(headers_hash)
        initialize_tracker
        current_time = Time.now
        fingerprint = headers_hash
        
        # Clean old entries (older than 5 seconds)
        @header_tracker.delete_if { |time, _| current_time - time > 5 }
        
        # Count recent occurrences of this specific fingerprint
        matching_count = @header_tracker.count { |time, fp| fp == fingerprint && (current_time - time) <= 5 }
        
        # Add current occurrence
        @header_tracker[current_time] = fingerprint
        
        matching_count
      end
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
        @log_id ||= "SPAM_#{Time.now.to_i}"
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
        domain.match(/(?:[a-zA-Z0-9-]+\.)*[a-zA-Z0-9-]+\.[a-zA-Z]{2,}/).to_s
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
          awstrack.me
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
      
      def check_from_name_email_mismatch(from_header)
        return 0 unless from_header
        
        # Extract name and email from "Name <email@domain.com>" format
        match = from_header.match(/^(?:"?([^"]+)"?\s*)?<([^>]+)>$/)
        return 0 unless match
        
        name = match[1]&.strip&.downcase
        email = match[2]&.downcase
        
        return 0 unless name && email && email.include?('@')
        
        domain = email.split('@').last
        
        # Check if name contains company keywords but domain doesn't match
        company_name_present = COMPANY_KEYWORDS.any? { |keyword| name.include?(keyword) }
        domain_matches_company = name.split.any? { |word| domain.include?(word) }
        
        # High penalty if company name in From but domain doesn't reflect it
        if company_name_present && !domain_matches_company
          log "From name contains company keywords but domain doesn't match: #{from_header}"
          return 5
        end
        
        # Check for suspicious generated emails
        if email.match?(/^[a-f0-9]{8,}@/i) || email.match?(/\d{3,}@/)
          log "Suspicious generated email detected: #{email}"
          return 3
        end
        
        0
      end
      
      def check_restricted_domain_priority(headers, from_domain)
        return 0 unless from_domain && RESTRICTED_DOMAINS.include?(from_domain)
        
        headers_text = headers.join(' ').downcase
        
        # Check for priority indicators
        priority_found = PRIORITY_INDICATORS.any? { |indicator| headers_text.include?(indicator) }
        
        if priority_found
          log "Priority email from restricted domain detected: #{from_domain}"
          return 10 # Very high penalty
        end
        
        0
      end
      
      def check_suspicious_confirmation_phrases(subject, body)
        text = (subject.to_s + ' ' + body.to_s).downcase
        
        count = SUSPICIOUS_CONFIRMATION_PHRASES.sum do |phrase|
          text.scan(/#{Regexp.escape(phrase)}/i).size
        end
        
        log "#{count} suspicious confirmation phrases found" if count > 0
        count
      end
      
      def extract_domain_from_email(email)
        return nil unless email
        # Extract domain from email address, handling various formats
        email.match(/@([^>\s]+)/)&.captures&.first
      end
                  
      def classify_email(sender_email, parsed, headers = [], subject = '')
        links = extract_links(parsed)
        bad_links = check_for_spam_links(links)
        mismatched = check_for_mismatched_sender(sender_email, links)

        parsed = strip_html(parsed)
        body_str = parsed.to_s.dup.force_encoding('UTF-8').scrub
        body_lower = body_str.downcase
        
        # Extract From header for name/email mismatch detection
        from_header = headers.find { |h| h.match?(/^From:/i) }
        from_domain = extract_domain_from_email(sender_email)
        
        # Track header fingerprint for rate limiting
        headers_fingerprint = headers.sort.join('|')
        header_frequency = track_header_fingerprint(headers_fingerprint)
        
        # Apply rate limiting penalty
        if header_frequency > 5
          log "High frequency headers detected: #{header_frequency} occurrences in 5 seconds"
        end
        
        # New detection methods
        from_mismatch_score = check_from_name_email_mismatch(from_header)
        restricted_domain_score = check_restricted_domain_priority(headers, from_domain)
        confirmation_phrases_score = check_suspicious_confirmation_phrases(subject, body_lower)

        gibberish_pattern = /(?<![aeiouy])[aeiouy]{3,}(?![aeiouy])|(?<![bcdfghjklmnpqrstvwxyz])[bcdfghjklmnpqrstvwxyz]{3,}(?![bcdfghjklmnpqrstvwxyz])/
        contains_gibberish = body_lower.match?(gibberish_pattern)

        marketing_count = count_keywords(MARKETING_KEYWORDS, body_lower)
        spam_count = count_keywords(SPAM_PHRASES, body_lower)
        offensive_count = count_keywords(OFFENSIVE_PHRASES, body_lower)
        pornographic_count = count_keywords(PORNOGRAPHIC_PHRASES, body_lower)

        finance_matches = body_lower.scan(FINANCE_REGEX).uniq
        finance_count = finance_matches.size

        finance_matches1 = body_lower.scan(FINANCE_REGEX1).uniq
        finance_count1 = finance_matches1.size
        
        log "#{finance_count} finance count"
        log "#{marketing_count} marketing count"
        log "#{offensive_count} offsensive count"
        log "#{finance_count1} finance1 count"
        log "#{from_mismatch_score} from name/email mismatch score"
        log "#{restricted_domain_score} restricted domain score"
        log "#{confirmation_phrases_score} confirmation phrases score"

        score = 0
        
        # Apply rate limiting penalty first
        if header_frequency > 5
          score += 15
        end
        
        # Add all other scores
        score += 1.5 * bad_links
        mismatchScore = (bad_links > 0 ? 0.5 : 0) * mismatched
        score += (mismatchScore > 4 ? 4 : mismatchScore)
        score += (contains_gibberish ? 1 : 0)
        score += 0.5 * marketing_count
        score += 1 * spam_count
        score += 1.5 * offensive_count
        score += 2 * pornographic_count
        score += 1.5 * finance_count
        score += (finance_count > 0 ? 0.5 : 0) * finance_count1
        
        # Add new detection scores
        score += from_mismatch_score
        score += restricted_domain_score
        score += 2 * confirmation_phrases_score

        #use wordiness to determine newsletter
        if body_lower.length > 2000 && body_lower.include?('unsubscribe')
          length = body_lower.length
          lower_bound = 2000.0
          upper_bound = 12000.0
          min_divisor = 2.0
          max_divisor = 10.0
          
          # Calculate reduction factor
          if length <= lower_bound
            reduction_factor = min_divisor
          elsif length >= upper_bound
            reduction_factor = max_divisor
          else
            reduction_factor = min_divisor + ((max_divisor - min_divisor) * (length - lower_bound) / (upper_bound - lower_bound))
          end
      
          score /= reduction_factor
        end
        
        [[score, 1].max, 20].min
      end

      private

      def strip_html(content)
        Nokogiri::HTML(content).text
      end

      def count_keywords(keywords, body)
        keywords.sum do |keyword|
          body.scan(/#{Regexp.escape(keyword)}/i).uniq.size
        end
      end      
    end
  end
end
