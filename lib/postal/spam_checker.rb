require 'nokogiri'
require 'uri'

module Postal
  class SpamChecker
    # Maximum content sizes to prevent resource exhaustion
    MAX_EMAIL_SIZE = 1_000_000  # 1MB
    MAX_SUBJECT_SIZE = 10_000   # 10KB
    MAX_BODY_SIZE = 500_000     # 500KB
    
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
    'venmail.io',
    'instagr.am',
    'youtube.com',
    'youtu.be',
    # Legitimate email service and marketing domains
    'mailchimp.com',
    'list-manage.com',
    'mcsv.net',
    'sendgrid.net',
    'sendgrid.com',
    'campaignmonitor.com',
    'campaignmonitor.com.au',
    'constantcontact.com',
    'ctct.com',
    'hubspot.com',
    'hs-sites.com',
    'hubspotemail.net',
    'convertkit.com',
    'convertkit-mail.com',
    'klaviyo.com',
    'klclick.com',
    'aweber.com',
    'aweber.net',
    'getresponse.com',
    'mailgun.org',
    'mailgun.com',
    'mandrillapp.com',
    'postmarkapp.com',
    'sparkpost.com',
    'sparkpostmail.com',
    'sendinblue.com',
    'brevo.com',
    'activecampaign.com',
    'drip.com',
    'customer.io',
    'omnisend.com'
    ].freeze

    MARKETING_KEYWORDS = [
    'limited time offer',
    'discounted price',
    'exclusive deal',
    'special offer',
    'new arrival',
    'earn more',
    'best deal ever',
    'extra income',
    'buy now',
    'buy more',
    'sell more',
    'work from home',
    'free shipping',
    'money-making',
    'huge discount',
    'clearance sale'
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
    agreement\s*with\s*me | 
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
      'venia.cloud', 
      'bammby.com'
    ].freeze

    # Legitimate system and security phrases that should not be penalized
    LEGITIMATE_SYSTEM_PHRASES = [
      'password reset',
      'reset password',
      'account verification',
      'password change',
      'security notification',
      'login notification',
      'two-factor authentication',
      '2fa',
      'verification code',
      'security code',
      'no further action required',
      'will expire in',
      'if you did not request',
      'please ignore',
      'regards',
      'notification',
      'confirm your email',
      'email verification',
      'verify your email'
    ].freeze

    # Legitimate business and onboarding phrases that should not be penalized
    LEGITIMATE_BUSINESS_PHRASES = [
      'welcome to',
      'thrilled to have you',
      'on board',
      'dedicated to',
      'business communications',
      'customer support',
      'get started',
      'best regards',
      'ceo',
      'thank you for choosing',
      'grow your business',
      'business communication',
      'business operations',
      'dedicated support',
      'easy account setup',
      'company staff'
    ].freeze

    # Legitimate meeting and collaboration phrases that should not be penalized
    LEGITIMATE_MEETING_PHRASES = [
      'meeting access granted',
      'access granted',
      'instant meeting',
      'join meeting',
      'meeting invitation',
      'meeting scheduled',
      'meeting reminder',
      'meeting confirmed',
      'meeting details',
      'virtual meeting',
      'online meeting',
      'meeting link',
      'join now',
      'meeting host',
      'meeting duration',
      'meeting location'
    ].freeze

    # Suspicious confirmation phrases
    SUSPICIOUS_CONFIRMATION_PHRASES = [
      'shipment confirmation',
      'shipping confirmed',
      'money received',
      'wallet updated',
      'health check',
      'payment received',
      'account verification',
      'address update required',
      'delivery confirmation',
      'package dispatched',
      'order confirmed',
      'payment processed',
      'transaction completed',
      'temporarily restricted',
      'account suspended',
      'account has been suspended',
      'appeal',
      'community standards',
      'intellectual property',
      'ownership rights',
      'ownership verification',
      'resolution center'
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

    # Greeting patterns that may include email addresses
    GREETING_PATTERNS = [
      'hello',
      'hi',
      'dear',
      'greetings',
      'good morning',
      'good afternoon',
      'good evening'
    ].freeze

    TARGETED_URGENCY_PHRASES = [
      'update immediately',
      'address update required',
      'address confirmation required',
      'respond within 24 hours',
      'within 24 hours',
      '24 hours',
      'final reminder',
      'final notice',
      'shipment on hold',
      'delivery awaiting confirmation',
      'permanently suspended',
      'temporarily restricted'
    ].freeze

    # Known brands that are commonly impersonated
    IMPERSONATED_BRANDS = [
      'meta', 'facebook', 'instagram', 'whatsapp', 'messenger',
      'google', 'gmail', 'youtube', 'drive', 'workspace',
      'apple', 'icloud', 'app store', 'itunes',
      'microsoft', 'outlook', 'office', 'teams', 'azure',
      'amazon', 'aws', 'prime',
      'netflix', 'spotify', 'linkedin', 'twitter', 'x',
      'paypal', 'venmo', 'cash app', 'zelle',
      'chase', 'bank of america', 'wells fargo', 'citibank',
      'dropbox', 'slack', 'zoom', 'adobe', 'salesforce'
    ].freeze

    # Patterns indicating random/official-looking but fake sender addresses
    RANDOM_SENDER_PATTERNS = [
      # Long random usernames before @
      /^[a-z]{20,}@/i,
      # Consonant-heavy random strings
      /^[bcdfghjklmnpqrstvwxyz]{12,}@/i,
      # Repeated character patterns
      /^([a-z])\1{8,}@/i,
      # Sequential patterns
      /^(abc|xyz|123|qwe|asd|zxc)[a-z]*@/i
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
      
      def check_brand_domain_mismatch(subject, body_lower, sender_domain)
        return 0 unless sender_domain && (subject || body_lower)
        
        score = 0
        text = (subject.to_s + ' ' + body_lower.to_s).downcase
        sender_domain = sender_domain.downcase
        
        # Skip if sender is already trusted
        return 0 if TRUSTED_DOMAINS.any? { |domain| sender_domain.end_with?(domain) }
        
        IMPERSONATED_BRANDS.each do |brand|
          next unless text.include?(brand)
          
          # Check if sender domain contains the brand name
          domain_contains_brand = sender_domain.include?(brand)
          
          # Allow some common TLD variations for legitimate domains
          legitimate_variants = [
            "#{brand}.com", "#{brand}.org", "#{brand}.net",
            "#{brand}.io", "#{brand}.co", "#{brand}.app",
            "get#{brand}.com", "#{brand}support.com"
          ]
          is_legitimate_variant = legitimate_variants.any? { |variant| sender_domain.include?(variant) }
          
          unless domain_contains_brand || is_legitimate_variant
            log "Brand/domain mismatch detected: '#{brand}' mentioned but sender is #{sender_domain}"
            score += 6
          end
        end
        
        score
      end
      
      def check_random_sender_address(sender_email)
        return 0 unless sender_email
        
        local_part = sender_email.split('@').first&.downcase
        return 0 unless local_part
        
        # Check against random patterns
        RANDOM_SENDER_PATTERNS.each do |pattern|
          if local_part.match?(pattern)
            log "Random sender address detected: #{sender_email}"
            return 4
          end
        end
        
        # Additional checks for suspicious characteristics
        score = 0
        
        # Very long usernames
        if local_part.length > 25
          log "Very long username detected: #{sender_email}"
          score += 2
        end
        
        # High consonant-to-vowel ratio (common in random strings)
        consonants = local_part.count('bcdfghjklmnpqrstvwxyz')
        vowels = local_part.count('aeiou')
        if vowels > 0 && (consonants.to_f / vowels) > 4
          log "High consonant/vowel ratio: #{sender_email}"
          score += 2
        end
        
        # Contains numbers mixed with letters in suspicious patterns
        if local_part.match?(/\d{3,}/) && local_part.match?(/[a-z]{5,}/)
          log "Suspicious alphanumeric pattern: #{sender_email}"
          score += 1
        end
        
        score
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
        
        # Add meeting platform patterns to reduce false positives
        meeting_platform_patterns = [
          /meet|meeting|zoom|teams|webex|gotomeeting|join\.me|hangouts/i,
          /venmail\.io\/meet/i
        ]

        spam_links_count = 0
        links.each do |href, labels|
          next if trusted_domains_regex.match?(href)
          next if href.nil? || href.empty?
          next unless href.is_a?(String)
          next if href.start_with?('mailto:')
          
          # Skip meeting platform URLs
          is_meeting_link = meeting_platform_patterns.any? { |pattern| href.match?(pattern) }
          if is_meeting_link
            log "Skipping meeting platform URL: #{href}"
            next
          end

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
        # Extracting base domain from href using regex with safe navigation
        match = href.match(/^(?:https?:\/\/)?(?:[^@\/\n]+@)?(?:www\.)?([^:\/?\n]+)/im)
        match&.[](1)
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
      
      def check_suspicious_confirmation_phrases(subject, body, sender_email = nil)
        text = (subject.to_s + ' ' + body.to_s).downcase
        
        # Skip confirmation phrase checks for legitimate senders
        return 0 if sender_email && legitimate_sender?(sender_email, text)
        
        count = SUSPICIOUS_CONFIRMATION_PHRASES.sum do |phrase|
          text.scan(/#{Regexp.escape(phrase)}/i).size
        end
        
        log "#{count} suspicious confirmation phrases found" if count > 0
        count
      end
      
      def legitimate_sender?(sender_email, body_text = nil)
        return false unless sender_email
        
        domain = extract_domain_from_email(sender_email)
        return false unless domain
        
        # Check if sender domain is trusted
        return false unless TRUSTED_DOMAINS.any? { |trusted| domain.end_with?(trusted) }
        
        # For venmail.io, require 'venmail' to be present in email content
        if domain.include?('venmail.io')
          return false unless body_text&.downcase&.include?('venmail')
        end
        
        true
      end
      
      def extract_domain_from_email(email)
        return nil unless email.is_a?(String) && !email.empty?
        
        # Basic email format validation
        return nil unless email.match?(/\A[^@\s]+@[^@\s]+\z/)
        
        # Extract domain and validate format
        domain = email.match(/@([^>\s]+)/)&.captures&.first
        return nil unless domain
        
        # Validate domain has proper format and TLD
        return nil unless domain.match?(/\A[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z/)
        return nil unless domain.start_with?(/[a-zA-Z0-9]/)
        
        domain
      end
      
      def check_phishing_tracking_links(links)
        return 0 unless links.is_a?(Hash)
        
        phishing_score = 0
        
        links.each do |href, labels|
          next if href.nil? || href.empty?
          next unless href.is_a?(String)
          next if href.start_with?('mailto:')
          
          # Parse the URL with proper error handling
          begin
            uri = URI.parse(href.downcase)
            next unless uri.host
            
            host = uri.host
            path = uri.path + (uri.query ? "?#{uri.query}" : "")
            
            # Extract base domain from host
            base_domain = extract_href_base_domain(href)
            next unless base_domain
            
            # Check if path contains service names that don't match the domain
            # Using existing tracking domains and trusted domains for reference
            service_names = ['sendgrid', 'mailchimp', 'mandrill', 'campaign', 'hubspot', 'mailgun', 
                           'postmark', 'sparkpost', 'ses', 'sendinblue', 'brevo', 'activecampaign',
                           'drip', 'convertkit', 'klaviyo', 'aweber', 'getresponse']
            
            service_names.each do |service|
              if path.include?(service) && !base_domain.include?(service)
                log "Phishing tracking link: #{host} contains '#{service}' in URL but domain doesn't match"
                phishing_score += 8
                break
              end
            end
            
          rescue URI::InvalidURIError
            # Invalid URL, skip
            next
          end
        end
        
        log "#{phishing_score} phishing tracking link points found" if phishing_score > 0
        phishing_score
      end
      
      def email_greeting_urgency_score(body_text, subject, headers, sender_domain, confirmation_score, phishing_score, restricted_score)
        return 0 unless body_text && subject
        text = body_text.to_s
        normalized_body = text.downcase
        normalized_subject = subject.to_s.downcase
        greeting_pattern = GREETING_PATTERNS.map { |g| Regexp.escape(g) }.join('|')
        greeting_email_regex = /\b(?:#{greeting_pattern})\s+[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}(?:\b|[,!.\s])/i

        greeting_match = text.match?(greeting_email_regex)
        return 0 unless greeting_match

        headers_text = headers.join(' ').downcase
        priority_hit = PRIORITY_INDICATORS.any? do |indicator|
          headers_text.include?(indicator) || normalized_subject.include?(indicator)
        end

        urgency_phrase_hit = TARGETED_URGENCY_PHRASES.any? do |phrase|
          normalized_body.include?(phrase) || normalized_subject.include?(phrase)
        end

        return 0 unless priority_hit || urgency_phrase_hit
        return 0 unless confirmation_score.to_f > 0

        sender_domain = sender_domain.to_s.downcase
        trusted_sender = TRUSTED_DOMAINS.any? { |domain| sender_domain.end_with?(domain) }
        return 0 if trusted_sender

        score = 2
        score += 1 if restricted_score.to_f > 0
        score += 1 if phishing_score.to_f > 0

        score = [score, 5].min
        log "Email greeting + urgency heuristic triggered with score #{score}"
        score
      end
                   
      def classify_email(sender_email, parsed, headers = [], subject = '')
        # Input validation and size limits
        return 20 unless sender_email.is_a?(String)
        return 20 unless subject.is_a?(String) && subject.length <= MAX_SUBJECT_SIZE
        return 20 unless parsed.is_a?(String) && parsed.length <= MAX_BODY_SIZE
        
        # Check total email size
        total_size = (sender_email.length + subject.length + parsed.length + headers.join.length)
        return 20 if total_size > MAX_EMAIL_SIZE
        
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
        confirmation_phrases_score = check_suspicious_confirmation_phrases(subject, body_lower, sender_email)
        phishing_tracking_score = check_phishing_tracking_links(links)
        brand_domain_mismatch_score = check_brand_domain_mismatch(subject, body_lower, from_domain)
        random_sender_score = check_random_sender_address(sender_email)
        greeting_urgency_score = email_greeting_urgency_score(
          body_str,
          subject,
          headers,
          from_domain,
          confirmation_phrases_score,
          phishing_tracking_score,
          restricted_domain_score
        )

        gibberish_pattern = /(?<![aeiouy])[aeiouy]{3,}(?![aeiouy])|(?<![bcdfghjklmnpqrstvwxyz])[bcdfghjklmnpqrstvwxyz]{3,}(?![bcdfghjklmnpqrstvwxyz])/
        contains_gibberish = body_lower.match?(gibberish_pattern)

        marketing_count = count_keywords(MARKETING_KEYWORDS, body_lower, sender_email)
        spam_count = count_keywords(SPAM_PHRASES, body_lower, sender_email)
        offensive_count = count_keywords(OFFENSIVE_PHRASES, body_lower, sender_email)
        pornographic_count = count_keywords(PORNOGRAPHIC_PHRASES, body_lower, sender_email)

        finance_matches = body_lower.scan(FINANCE_REGEX).uniq
        finance_count = count_finance_patterns(body_lower, sender_email)

        finance_matches1 = body_lower.scan(FINANCE_REGEX1).uniq
        finance_count1 = finance_matches1.size
        
        log "#{finance_count} finance count"
        log "#{marketing_count} marketing count"
        log "#{offensive_count} offsensive count"
        log "#{finance_count1} finance1 count"
        log "#{from_mismatch_score} from name/email mismatch score"
        log "#{restricted_domain_score} restricted domain score"
        log "#{confirmation_phrases_score} confirmation phrases score"
        log "#{phishing_tracking_score} phishing tracking links score"
        log "#{brand_domain_mismatch_score} brand/domain mismatch score"
        log "#{random_sender_score} random sender address score"
        log "#{greeting_urgency_score} email greeting urgency score"

        score = 0
        
        # Check if this is a legitimate system/security email and apply score reduction
        system_phrases_count = LEGITIMATE_SYSTEM_PHRASES.sum do |phrase|
          body_lower.scan(/#{Regexp.escape(phrase)}/i).size
        end
        
        # Check if this is a legitimate business email and apply score reduction
        business_phrases_count = LEGITIMATE_BUSINESS_PHRASES.sum do |phrase|
          body_lower.scan(/#{Regexp.escape(phrase)}/i).size
        end
        
        # Check if this is a legitimate meeting email and apply score reduction
        meeting_phrases_count = LEGITIMATE_MEETING_PHRASES.sum do |phrase|
          body_lower.scan(/#{Regexp.escape(phrase)}/i).size
        end
        
        is_system_email = system_phrases_count >= 2  # At least 2 system phrases
        is_business_email = business_phrases_count >= 3  # At least 3 business phrases
        is_meeting_email = meeting_phrases_count >= 2  # At least 2 meeting phrases
        
        if is_system_email
          log "Legitimate system email detected (#{system_phrases_count} system phrases), applying score reduction"
        end
        
        if is_business_email
          log "Legitimate business email detected (#{business_phrases_count} business phrases), applying score reduction"
        end
        
        if is_meeting_email
          log "Legitimate meeting email detected (#{meeting_phrases_count} meeting phrases), applying score reduction"
        end
        
        # Apply rate limiting penalty first
        if header_frequency > 5
          score += 15
          log "Rate limiting penalty applied: +15"
        end
        
        # Add all other scores
        if bad_links > 0
          score += 1.5 * bad_links
          log "Bad links penalty: +#{1.5 * bad_links}"
        end
        
        mismatchScore = (bad_links > 0 ? 0.5 : 0) * mismatched
        if mismatchScore > 0
          score += (mismatchScore > 4 ? 4 : mismatchScore)
          log "Sender mismatch penalty: +#{[mismatchScore, 4].min}"
        end
        
        if contains_gibberish
          score += 1
          log "Gibberish penalty: +1"
        end
        
        if marketing_count > 0
          marketing_score = 0.25 * marketing_count
          marketing_score = [marketing_score, 3.0].min
          score += marketing_score
          log "Marketing keywords penalty: +#{marketing_score}"
        end
        
        if spam_count > 0
          score += 1 * spam_count
          log "Spam phrases penalty: +#{spam_count}"
        end
        
        if offensive_count > 0
          score += 1.5 * offensive_count
          log "Offensive content penalty: +#{1.5 * offensive_count}"
        end
        
        if pornographic_count > 0
          score += 2 * pornographic_count
          log "Pornographic content penalty: +#{2 * pornographic_count}"
        end
        
        if finance_count > 0
          score += 1.5 * finance_count
          log "Finance patterns penalty: +#{1.5 * finance_count}"
        end
        
        if finance_count1 > 0
          score += (finance_count > 0 ? 0.5 : 0) * finance_count1
          log "Finance patterns1 penalty: +#{(finance_count > 0 ? 0.5 : 0) * finance_count1}"
        end
        
        # Add new detection scores
        if from_mismatch_score > 0
          score += from_mismatch_score
          log "From name/email mismatch penalty: +#{from_mismatch_score}"
        end
        
        if restricted_domain_score > 0
          score += restricted_domain_score
          log "Restricted domain penalty: +#{restricted_domain_score}"
        end
        
        if confirmation_phrases_score > 0
          score += 2 * confirmation_phrases_score
          log "Confirmation phrases penalty: +#{2 * confirmation_phrases_score}"
        end
        
        if phishing_tracking_score > 0
          score += phishing_tracking_score
          log "Phishing tracking penalty: +#{phishing_tracking_score}"
        end
        
        if brand_domain_mismatch_score > 0
          score += brand_domain_mismatch_score
          log "Brand domain mismatch penalty: +#{brand_domain_mismatch_score}"
        end
        
        if random_sender_score > 0
          score += random_sender_score
          log "Random sender penalty: +#{random_sender_score}"
        end
        
        if greeting_urgency_score > 0
          score += greeting_urgency_score
          log "Greeting urgency penalty: +#{greeting_urgency_score}"
        end

        # Apply system, business, and meeting email score reductions if detected
        if is_system_email
          score *= 0.2  # Reduce score by 80% for legitimate system emails
          log "Applied system email score reduction: #{(score * 5).round(2)} -> #{score.round(2)}"
        end
        
        if is_business_email
          score *= 0.4  # Reduce score by 60% for legitimate business emails
          log "Applied business email score reduction: #{(score * 2.5).round(2)} -> #{score.round(2)}"
        end
        
        if is_meeting_email
          score *= 0.3  # Reduce score by 70% for legitimate meeting emails
          log "Applied meeting email score reduction: #{(score * 3.33).round(2)} -> #{score.round(2)}"
        end

        #use wordiness to determine newsletter
        if body_lower.length > 1024 && body_lower.include?('unsubscribe')
          length = body_lower.length
          lower_bound = 1024.0
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

      def count_keywords(keywords, text, sender_email = nil)
        # Skip keyword counting for legitimate senders
        return 0 if sender_email && legitimate_sender?(sender_email, text)
        
        keywords.sum do |keyword|
          text.scan(/#{Regexp.escape(keyword)}/i).size
        end
      end
      
      def count_finance_patterns(text, sender_email = nil)
        # Skip finance pattern detection for legitimate senders
        return 0 if sender_email && legitimate_sender?(sender_email, text)
        
        text.scan(FINANCE_REGEX).uniq.size
      end      
    end
  end
end
