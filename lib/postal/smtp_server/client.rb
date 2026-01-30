require 'resolv'
require 'nifty/utils/random_string'
require 'digest'
require 'unix_crypt'
require 'json'

module Postal
  module SMTPServer
    class Client
      CRAM_MD5_DIGEST = OpenSSL::Digest.new('md5')
      LOG_REDACTION_STRING = '[redacted]'.freeze
      ALIAS_CHECK_URLS = [
        'https://m.venmail.io/api/v1/checkalias',
        'https://app.venmail.io/api/v1/checkalias'
      ].freeze
      ALIAS_HTTP_TIMEOUT = 5

      attr_reader :logging_enabled

      def initialize(ip_address)
        @logging_enabled = true
        @ip_address = ip_address
        if @ip_address
          check_ip_address
          @state = :welcome
        else
          @state = :preauth
        end
        transaction_reset
      end

      def check_ip_address
        if @ip_address && Postal.config.smtp_server.log_exclude_ips && @ip_address =~ Regexp.new(Postal.config.smtp_server.log_exclude_ips)
          @logging_enabled = false
        end
      end

      def transaction_reset
        @recipients = []
        @mail_from = nil
        @data = nil
        @headers = nil
      end

      def id
        @id ||= Nifty::Utils::RandomString.generate(length: 6).upcase
      end

      def handle(data)
        return proxy(data) if @state == :preauth

        log "\e[32m<= #{sanitize_input_for_log(data.strip)}\e[0m"
        if @proc
          @proc.call(data)

        else
          handle_command(data)
        end
      end

      def sanitize_input_for_log(data)
        if @password_expected_next
          @password_expected_next = false
          return LOG_REDACTION_STRING if data =~ /\A[a-z0-9]{3,}=*\z/i
        end

        data = data.dup
        data.gsub!(/(.*AUTH \w+) (.*)\z/i) { "#{::Regexp.last_match(1)} #{LOG_REDACTION_STRING}" }
        data
      end

      def finished?
        @finished || false
      end

      def start_tls?
        @start_tls || false
      end

      attr_writer :start_tls

      def handle_command(data)
        case data
        when /^QUIT/i           then quit
        when /^STARTTLS/i       then starttls
        when /^EHLO/i           then ehlo(data)
        when /^HELO/i           then helo(data)
        when /^RSET/i           then rset
        when /^NOOP/i           then noop
        when /^AUTH PLAIN/i     then auth_plain(data)
        when /^AUTH LOGIN/i     then auth_login(data)
        when /^AUTH CRAM-MD5/i  then auth_cram_md5(data)
        when /^MAIL FROM/i      then mail_from(data)
        when /^RCPT TO/i        then rcpt_to(data)
        when /^DATA/i           then data(data)
        else
          '502 Invalid/unsupported command'
        end
      end

      def log(text)
        return false unless @logging_enabled

        Postal.logger_for(:smtp_server).debug "[#{id}] #{text}"
      end

      private

      def resolve_hostname
        Resolv::DNS.open do |dns|
          dns.timeouts = [10, 5]
          @hostname = begin
            dns.getname(@ip_address)
          rescue StandardError
            @ip_address
          end
        end
      end

      def proxy(data)
        if m = data.match(/\APROXY (.+) (.+) (.+) (.+) (.+)\z/)
          @ip_address = m[2]
          check_ip_address
          @state = :welcome
          log "\e[35m   Client identified as #{@ip_address}\e[0m"
          "220 #{Postal.config.dns.smtp_server_hostname} Venmail Core/#{id}"
        else
          @finished = true
          '502 Proxy Error'
        end
      end

      def quit
        @finished = true
        '221 Closing Connection'
      end

      def starttls
        if Postal.config.smtp_server.tls_enabled?
          @start_tls = true
          @tls = true
          '220 Ready to start TLS'
        else
          '502 TLS not available'
        end
      end

      def ehlo(data)
        resolve_hostname
        @helo_name = data.strip.split(' ', 2)[1]
        transaction_reset
        @state = :welcomed
        ['250-My capabilities are', Postal.config.smtp_server.tls_enabled? && !@tls ? '250-STARTTLS' : nil,
         '250 AUTH CRAM-MD5 PLAIN LOGIN']
      end

      def helo(data)
        resolve_hostname
        @helo_name = data.strip.split(' ', 2)[1]
        transaction_reset
        @state = :welcomed
        "250 #{Postal.config.dns.smtp_server_hostname}"
      end

      def rset
        transaction_reset
        @state = :welcomed
        '250 OK'
      end

      def noop
        '250 OK'
      end

      def auth_plain(data)
        handler = proc do |data|
          @proc = nil
          data = Base64.decode64(data)
          parts = data.split("\0")
          username = parts[-2]
          password = parts[-1]
          next '535 Authentication failed - protocol error' unless username && password

          authenticate(username, password)
        end

        data = data.gsub(/AUTH PLAIN ?/i, '')
        if data.strip == ''
          @proc = handler
          @password_expected_next = true
          '334'
        else
          handler.call(data)
        end
      end

      def auth_login(data)
        password_handler = proc do |data|
          @proc = nil
          password = Base64.decode64(data)
          authenticate(@username_buffer, password)
        end

        username_handler = proc do |data|
          @proc = password_handler
          @username_buffer = Base64.decode64(data)
          @password_expected_next = true
          '334 UGFzc3dvcmQ6' # "Password:"
        end

        data = data.gsub(/AUTH LOGIN ?/i, '')
        if data.strip == ''
          @proc = username_handler
          '334 VXNlcm5hbWU6' # "Username:"
        else
          username_handler.call(data)
        end
      end

      def authenticate(username, password)
        # Rate limit check
        if auth_blocked?(username)
          log "\e[33m   WARN: AUTH temporarily rate limited for #{username} from #{@ip_address}\e[0m"
          return '421 Temporarily rate limited'
        end
        # Check if the provided key (password) is a valid credential key
        if @credential = Credential.where(type: 'SMTP', key: password).first
          if @credential.hold?
            log "\e[33m   WARN: AUTH attempt with held credential (#{@credential.id})\e[0m"
            return '535 Invalid credential'
          end
          @credential.use
          record_auth_success(username)
          "235 Granted for #{@credential.server.organization.permalink}/#{@credential.server.permalink}"
        elsif valid_user_authentication?(username, password)
          # If not a valid credential key, treat it as regular username and password authentication
          record_auth_success(username)
          "235 Granted for #{username}"
        else
          log "\e[33m   WARN: AUTH failure for #{@ip_address}\e[0m"
          record_auth_failure(username)
          '535 Invalid credential'
        end
      end

      def valid_user_authentication?(email, input_password)
        # Extract domain from email
        domain = email.split('@').last&.downcase
        return false unless domain && domain.include?(".")

        # Lookup domain and get server
        dm = Domain.includes(:owner).where('LOWER(domains.name) = ?', domain).first
        log "\e[33m   WARN: Failed to get domain #{domain}\e[0m" unless dm
        return false unless dm
        server = dm&.owner

        log "\e[33m   WARN: Failed to find server #{dm.owner_id}\e[0m" unless server
        return false unless server

        if server.suspended?
          log "\e[33m   WARN: Mail server suspended\e[0m"
          return false
        end

        return false unless server.respond_to?(:message_db)

        # Query the database to retrieve the hashed password for the provided email
        user = server.message_db.mail_user.find(email)
        return false unless user

        hashed_password = user['password']
        return false unless hashed_password

        check = hashed_password[14..-1]
        result = UnixCrypt.valid?(input_password, check)

        if !result
          log "\e[33m   WARN: AUTH failure for #{email}\e[0m"
        else
          @domain = dm
          @server = server # Store server reference for later use
          server.message_db.mail_user.update_login(email)
        end

        result
      end

      def auth_cram_md5(_data)
        challenge = Digest::SHA1.hexdigest(Time.now.to_i.to_s + rand(100_000).to_s)
        challenge = "<#{challenge[0, 20]}@#{Postal.config.dns.smtp_server_hostname}>"

        handler = proc do |data|
          @proc = nil
          username, password = Base64.decode64(data).split(' ', 2).map { |a| a.chomp }
          org_permlink, server_permalink = username.split(%r{[/_]}, 2)
          server = ::Server.includes(:organization).where(organizations: { permalink: org_permlink },
                                                          permalink: server_permalink).first
          next '535 Denied' if server.nil?

          grant = nil
          # Rate limit check on CRAM-MD5 identity
          if auth_blocked?(username)
            next '421 Temporarily rate limited'
          end
          server.credentials.where(type: 'SMTP').each do |credential|
            next if credential.hold?
            correct_response = OpenSSL::HMAC.hexdigest(CRAM_MD5_DIGEST, credential.key, challenge)
            next unless password == correct_response

            @credential = credential
            @credential.use
            grant = "235 Granted for #{credential.server.organization.permalink}/#{credential.server.permalink}"
            break
          end
          if grant
            record_auth_success(username)
            grant
          else
            record_auth_failure(username)
            '535 Denied'
          end
        end

        @proc = handler
        '334 ' + Base64.encode64(challenge).gsub(/[\r\n]/, '')
      end

      def mail_from(data)
        return '503 EHLO/HELO first please' unless in_state(:welcomed, :mail_from_received)

        @state = :mail_from_received
        transaction_reset
        mail_from_line = if data =~ /AUTH=/
                           # Discard AUTH= parameter and anything that follows.
                           # We don't need this parameter as we don't trust any client to set it
                           data.sub(/ *AUTH=.*/, '')
                         else
                           data
                         end
        @mail_from = mail_from_line.gsub(/MAIL FROM\s*:\s*/i, '').gsub(/.*</, '').gsub(/>.*/, '').strip
        '250 OK'
      end

      def handle_alias_lookup(rcpt_to, tag)
        response = lookup_alias_info(rcpt_to)
        return nil unless response && response['found']

        main_email = response['main_email']&.strip
        unless main_email.present?
          log "Alias lookup returned without main email for #{rcpt_to}"
          return '550 Alias target is not available'
        end

        parts = main_email.rpartition('@')
        return '550 Alias target address invalid' unless parts[1] == '@'

        main_uname = parts[0]
        main_domain = parts[2]
        main_uname, _main_tag = main_uname.split('+', 2)

        resolved_route = Route.find_by_name_and_domain(main_uname, main_domain)
        unless resolved_route
          log "Alias lookup mapped #{rcpt_to} to #{main_email} but no route exists"
          return '550 Alias target route not found'
        end

        if resolved_route.server.suspended?
          return '535 Mail server has been suspended'
        elsif resolved_route.mode == 'Reject'
          return '550 Route does not accept incoming messages'
        end

        resolved_local = main_uname
        resolved_local += "+#{tag}" if tag && !tag.empty?
        resolved_rcpt_to = "#{resolved_local}@#{main_domain}"

        if resolved_rcpt_to && rcpt_to && resolved_rcpt_to.casecmp(rcpt_to).zero?
          return '550 Alias mapping loops'
        end

        @state = :rcpt_to_received
        log "Alias #{rcpt_to} resolved to route #{resolved_route.id} (#{resolved_rcpt_to})"
        @recipients << [:route, resolved_rcpt_to, resolved_route.server, { route: resolved_route, alias: rcpt_to, alias_main: main_email }]
        '250 OK'
      rescue => e
        log "Alias lookup error for #{rcpt_to}: #{e.message}"
        nil
      end

      def lookup_alias_info(address)
        ALIAS_CHECK_URLS.each do |url|
          response = Postal::HTTP.get(url, params: { alias: address }, timeout: ALIAS_HTTP_TIMEOUT)
          log "Alias lookup for #{address} via #{url}: #{response[:code]}"
          next unless response && response[:code] == 200 && response[:body].present?

          begin
            parsed = JSON.parse(response[:body])
            log "Alias lookup for #{address} via #{url}: #{parsed}"
            return parsed
          rescue JSON::ParserError => e
            log "Alias lookup parse failure for #{address} via #{url}: #{e.message}"
            next
          end
        end
        nil
      rescue => e
        log "Alias lookup request failed for #{address}: #{e.message}"
        nil
      end

      def rcpt_to(data)
        return '503 EHLO/HELO and MAIL FROM first please' unless in_state(:mail_from_received, :rcpt_to_received)

        begin
          # Extract RCPT TO address and clean it
          rcpt_to = data.gsub(/RCPT TO\s*:\s*/i, '').gsub(/.*</, '').gsub(/>.*/, '').strip
          
          # If empty or invalid, try alternate extraction
          if rcpt_to.blank? || rcpt_to.count('@') != 1
            if data =~ /<([^>]+@[^>]+)>/
              rcpt_to = $1.strip
            else
              # Fall back to basic email pattern matching
              rcpt_to = data.scan(/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/).first
            end
          end

          # Clean the email address of starting/trailing apostrophes, commas, and trailing periods
          rcpt_to = rcpt_to.sub(/^['"]+/, '').sub(/['"]+$/, '').gsub(/[,;]+/, '').sub(/\.$/, '').strip if rcpt_to

          return '501 RCPT TO should not be empty' if rcpt_to.blank?

          # Split email and handle edge cases
          parts = rcpt_to.rpartition('@')
          return '501 Invalid RCPT TO' unless parts[1] == '@'
          
          uname = parts[0]
          domain = parts[2]
          return '501 Invalid RCPT TO' if domain.blank?

          uname, tag = uname.split('+', 2)

          normalized_domain = domain.downcase
          normalized_uname = uname.downcase
          normalized_return_path_domain = Postal.config.dns.return_path.to_s.downcase
          normalized_custom_return_path_prefix = Postal.config.dns.custom_return_path_prefix.to_s.downcase

          custom_return_path_match = normalized_custom_return_path_prefix.present? && normalized_domain.start_with?("#{normalized_custom_return_path_prefix}.")

          if !Postal.config.smtp_server.disable_bounce_return_path && (normalized_domain == normalized_return_path_domain || custom_return_path_match)
            # Original return path handling...
            @state = :rcpt_to_received
            if server = ::Server.where(token: uname).first
              if server.suspended?
                '535 Mail server has been suspended'
              else
                log "Added bounce on server #{server.id}"
                @recipients << [:bounce, rcpt_to, server]
                '250 OK'
              end
            else
              '550 Invalid server token'
            end

          elsif normalized_domain == Postal.config.dns.route_domain.to_s.downcase
            # Original route domain handling...
            @state = :rcpt_to_received
            if route = Route.where(token: uname).first
              if route.server.suspended?
                '535 Mail server has been suspended'
              elsif route.mode == 'Reject'
                '550 Route does not accept incoming messages'
              else
                log "Added route #{route.id} to recipients (tag: #{tag.inspect})"
                actual_rcpt_to = "#{route.name}" + (tag ? "+#{tag}" : '') + "@#{route.domain.name}"
                @recipients << [:route, actual_rcpt_to, route.server, { route: route }]
                '250 OK'
              end
            else
              '550 Invalid route token'
            end

          elsif route = Route.find_by_name_and_domain(normalized_uname, normalized_domain)
            # Original route handling...
            @state = :rcpt_to_received
            if route.server.suspended?
              '535 Mail server has been suspended'
            elsif route.mode == 'Reject'
              '550 Route does not accept incoming messages'
            else
              log "Added route #{route.id} to recipients (tag: #{tag.inspect})"
              @recipients << [:route, rcpt_to, route.server, { route: route }]
              '250 OK'
            end

          elsif (alias_response = handle_alias_lookup(rcpt_to, tag))
            alias_response

          elsif @credential || @domain
            # Handle authenticated sending
            @state = :rcpt_to_received
            server = @domain ? @domain.owner : @credential.server
            if server.suspended?
              '535 Mail server has been suspended'
            else
              recipient_domain = rcpt_to.split('@').last&.downcase
              if recipient_domain && Domain.where('LOWER(name) = ?', recipient_domain).where(owner: server).exists?
                '550 Cannot send to local domain without a route'
              else
                log "Added external address '#{rcpt_to}'"
                @recipients << [:credential, rcpt_to, server]
                '250 OK'
              end
            end
            
          else
            # Original IP authentication attempt...
            @credential = Credential.where(type: 'SMTP-IP').all.sort_by { |c|
              c.ipaddr&.prefix || 0
            }.reverse.find { |credential|
              credential.ipaddr.include?(@ip_address)
            }          
            if @credential
              if @credential.hold?
                log "\e[33m   WARN: SMTP-IP auth blocked for held credential (#{@credential.id})\e[0m"
                '535 Invalid credential'
              else
                @credential.use
                rcpt_to(data)
              end
            else
              parts = @mail_from.rpartition('@')
              domain = parts[2]&.downcase.presence
              dm = Domain.includes(:owner).where('LOWER(domains.name) = ?', domain).first if domain
              if !dm
                parts = @mail_from.rpartition('@nia.')
                domain = parts[2]&.downcase.presence
                dm = Domain.includes(:owner).where('LOWER(domains.name) = ?', domain).first if domain
              end
              log "\e[33m   WARN: Failed to find domain #{@mail_from}\e[0m" unless dm
              if dm && (server = dm.owner)
                @credential = Credential.where(server_id: server.id).first
                if @credential
                  if @credential.hold?
                    log "\e[33m   WARN: SMTP-IP inferred auth blocked for held credential (#{@credential.id})\e[0m"
                    '535 Invalid credential'
                  else
                    @credential.use
                    rcpt_to(data)
                  end
                else
                  log "No credential found for server #{server.id}"
                  '530 Authentication required'
                end
              else
                log "Domain missing or no associated server"
                '530 Authentication required'
              end
            end
          end

        rescue => e
          log "RCPT TO parsing error: #{e.message}"
          '501 Invalid RCPT TO format'
        end
      end

      def data(_data)
        return '503 HELO/EHLO, MAIL FROM and RCPT TO before sending data' unless in_state(:rcpt_to_received)

        @data = ''.force_encoding('BINARY')
        @headers = {}
        @receiving_headers = true

        received_header_content = "from #{@helo_name} (#{@hostname} [#{@ip_address}]) by #{Postal.config.dns.smtp_server_hostname} with SMTP; #{Time.now.utc.rfc2822}".force_encoding('BINARY')
        @data << "Received: #{received_header_content}\r\n" unless Postal.config.smtp_server.strip_received_headers?
        @headers['received'] = [received_header_content]

        handler = proc do |data|
          if data == '.'
            @logging_enabled = true
            @proc = nil
            finished
          else
            data = data.to_s.sub(/\A\.\./, '.')
            
            # Detect Resent-Sender in headers as they arrive
            if @receiving_headers && data =~ /^Resent-Sender:/i
              log "Debug: Detected Resent-Sender header in incoming message"
            end
            
            if @credential && @credential.server.log_smtp_data?
              # We want to log if enabled
            else
              log 'Not logging further message data.'
              @logging_enabled = false
            end

            if @receiving_headers
              if data.blank?
                @receiving_headers = false
              elsif data.to_s =~ /^\s/
                # This is a continuation of a header
                if @header_key && @headers[@header_key.downcase] && @headers[@header_key.downcase].last
                  @headers[@header_key.downcase].last << data.to_s
                end
                # If received headers are configured to be stripped and we're currently receiving one
                # skip the append methods at the bottom of this loop.
                if Postal.config.smtp_server.strip_received_headers? && @header_key && @header_key.downcase == 'received'
                  next
                end
              else
                @header_key, value = data.split(/:\s*/, 2)
                @headers[@header_key.downcase] ||= []
                @headers[@header_key.downcase] << value
                # As above
                if Postal.config.smtp_server.strip_received_headers? && @header_key && @header_key.downcase == 'received'
                  next
                end
              end
            end
            @data << data
            @data << "\r\n"
            nil
          end
        end

        @proc = handler
        '354 Go ahead'
      end

      def finished
        if @data.bytesize > Postal.config.smtp_server.max_message_size.megabytes.to_i
          transaction_reset
          @state = :welcomed
          return '552 Message too large (maximum size %dMB)' % Postal.config.smtp_server.max_message_size
        end

        # More strict Resent-Sender checking
        resent_headers = @data.scan(/^Resent-[^:]+:/i)
        log "Debug: Message contains #{resent_headers.count} Resent-* headers"
        
        if resent_headers.count > 3
          log "Rejecting message with too many Resent headers (#{resent_headers.count})"
          transaction_reset
          @state = :welcomed
          return '550 Message appears to be in a forwarding loop'
        end

        loop_value = Postal.config.dns.smtp_server_hostname.to_s
        existing_loop_values = Array(@headers['x-postal-loop']).map { |v| v.to_s.strip.downcase }
        if existing_loop_values.include?(loop_value.downcase)
          log "Rejecting message with X-Postal-Loop: #{loop_value}"
          transaction_reset
          @state = :welcomed
          return '550 Message appears to be in a forwarding loop'
        end
        unless existing_loop_values.include?(loop_value.downcase)
          header_insert = "X-Postal-Loop: #{loop_value}\r\n"
          if (idx = @data.index("\r\n\r\n"))
            # Insert before the blank line separator, not at it
            @data.insert(idx + 2, header_insert)
          else
            @data << header_insert << "\r\n"
          end
          @headers['x-postal-loop'] ||= []
          @headers['x-postal-loop'] << loop_value
        end
        # Validate From header matches authenticated domain
        if @credential || @domain
          # Extract the From header
          from_header = @headers['from']&.first
          unless from_header
            log "Rejected: No From header present"
            transaction_reset
            @state = :welcomed
            return '550 From header is required'
          end

          # Extract domain from From header
          from_domain = nil
          begin
            from_email = from_header.match(/<([^>]+@[^>]+)>/)&.[](1) || from_header.scan(/\S+@\S+/).first
            from_domain = from_email&.split('@')&.last&.downcase
          rescue StandardError => e
            log "Error parsing From header: #{e.message}"
          end

          unless from_domain
            log "Rejected: Could not parse domain from From header"
            transaction_reset
            @state = :welcomed
            return '550 Invalid From header format'
          end

          # Get the authenticated domain
          authenticated_domain = nil
          if @domain
            authenticated_domain = @domain.name
          else
            authenticated_domain = @credential.server.find_authenticated_domain_from_headers(@headers)&.name
          end

          # Log what we found for debugging
          log "Debug: From domain: #{from_domain}, Authenticated domain: #{authenticated_domain}"

          # Skip this check for internal/bounce messages
          if !@recipients.any? {|r| r[0] == :bounce} && authenticated_domain && from_domain != authenticated_domain
            log "Rejected: From domain #{from_domain} does not match authenticated domain #{authenticated_domain}"
            transaction_reset
            @state = :welcomed
            return '550 From domain does not match authentication'
          end
        end

        authenticated_domain = nil
        if @credential
          authenticated_domain = @credential.server.find_authenticated_domain_from_headers(@headers)
          
          # If no authenticated domain but block_outgoing_without_verified_route is enabled,
          # extract domain from From header for later validation in UnqueueMessageJob
          if authenticated_domain.nil? && @credential.server.block_outgoing_without_verified_route?
            from_header = @headers['from']&.first
            if from_header
              begin
                from_email = from_header.match(/<([^>]+@[^>]+)>/)&.[](1) || from_header.scan(/\S+@\S+/).first
                from_domain_name = from_email&.split('@')&.last&.downcase
                if from_domain_name
                  # Look up the domain in the database to set proper domain_id
                  authenticated_domain = Domain.where(name: from_domain_name).first
                  log "Found domain #{from_domain_name} for route validation: #{authenticated_domain ? 'yes' : 'no'}"
                end
              rescue StandardError => e
                log "Error extracting domain from From header for route validation: #{e.message}"
              end
            end
          end
          
          # If still no authenticated domain after all attempts, return error
          if authenticated_domain.nil?
            transaction_reset
            @state = :welcomed
            return '530 From/Sender name is not valid'
          end
        end

        @recipients.each do |recipient|
          type, rcpt_to, server, options = recipient

          case type
          when :credential
            # Outgoing messages are just inserted
            if @domain
              # Outgoing messages are just inserted
              server = @domain.owner
              message = server.message_db.new_message
              message.rcpt_to = rcpt_to
              message.mail_from = @mail_from
              message.raw_message = @data
              message.received_with_ssl = @tls
              message.scope = 'outgoing'
              message.domain_id = @domain&.id
              message.save
              message.original_mail_from = @mail_from
            else
              message = server.message_db.new_message
              message.rcpt_to = rcpt_to
              message.mail_from = @mail_from
              message.raw_message = @data
              message.received_with_ssl = @tls
              message.scope = 'outgoing'
              message.domain_id = authenticated_domain&.id
              message.credential_id = @credential.id
              message.save
              message.original_mail_from = @mail_from
            end

          when :bounce
            if rp_route = server.routes.where(name: '__returnpath__').first
              # If there's a return path route, we can use this to create the message
              rp_route.create_messages do |message|
                message.rcpt_to = rcpt_to
                message.mail_from = @mail_from
                message.raw_message = @data
                message.received_with_ssl = @tls
              end
            else
              # There's no return path route, we just need to insert the mesage
              # without going through the route.
              message = server.message_db.new_message
              message.rcpt_to = rcpt_to
              message.mail_from = @mail_from
              message.raw_message = @data
              message.received_with_ssl = @tls
              message.scope = 'incoming'
              message.bounce = 1
              message.save
            end
          when :route
            options[:route].create_messages do |message|
              message.rcpt_to = rcpt_to
              message.mail_from = @mail_from
              message.raw_message = @data
              message.received_with_ssl = @tls
            end
          end
        end
        transaction_reset
        @state = :welcomed
        '250 OK'
      end

      def in_state(*states)
        states.include?(@state)
      end

      # Rate limiter helpers
      def auth_limiter_window
        (Postal.config.general.compromise.hour_window rescue 3600).to_i
      end

      def auth_limiter_threshold
        (Postal.config.general.auth_limiter.max_failures rescue 10).to_i
      end

      def auth_limiter_block_seconds
        (Postal.config.general.auth_limiter.block_seconds rescue 900).to_i
      end

      def auth_scope_keys(username)
        keys = []
        keys << "ip:#{@ip_address}" if @ip_address
        keys << "user:#{username.to_s.downcase}" if username
        keys
      end

      def auth_blocked?(username)
        auth_scope_keys(username).any? do |key|
          if attempt = AuthAttempt.find_by(scope_key: key)
            attempt.blocked?
          else
            false
          end
        end
      end

      def record_auth_failure(username)
        now = Time.now
        window = auth_limiter_window
        limit = auth_limiter_threshold
        block_for = auth_limiter_block_seconds
        auth_scope_keys(username).each do |key|
          attempt = AuthAttempt.find_or_initialize_by(scope_key: key)
          if attempt.window_started_at && attempt.window_started_at > window.seconds.ago
            attempt.count = attempt.count.to_i + 1
          else
            attempt.window_started_at = now
            attempt.count = 1
          end
          if attempt.count > limit
            attempt.blocked_until = now + block_for
          end
          attempt.save
        end
      end

      def record_auth_success(username)
        auth_scope_keys(username).each do |key|
          if attempt = AuthAttempt.find_by(scope_key: key)
            attempt.update(:count => 0, :window_started_at => nil, :blocked_until => nil)
          end
        end
      end
    end
  end
end