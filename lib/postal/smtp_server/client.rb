require 'resolv'
require 'nifty/utils/random_string'
require 'digest'
require 'unix_crypt'

module Postal
  module SMTPServer
    class Client
      CRAM_MD5_DIGEST = OpenSSL::Digest.new('md5')
      LOG_REDACTION_STRING = '[redacted]'.freeze

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

      # [Previous methods unchanged...]

      def valid_user_authentication?(email, input_password)
        # Extract domain from email
        domain = email.split('@').last
        return false unless domain && domain.include?(".")

        # Lookup domain and get server
        dm = Domain.includes(:owner).where(name: domain).first
        log "\e[33m   WARN: Failed to find domain #{domain}\e[0m" unless dm
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

      def rcpt_to(data)
        return '503 EHLO/HELO and MAIL FROM first please' unless in_state(:mail_from_received, :rcpt_to_received)

        begin
          # Extract RCPT TO address
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

          return '501 RCPT TO should not be empty' if rcpt_to.blank?

          # Split email and handle edge cases
          parts = rcpt_to.rpartition('@')
          return '501 Invalid RCPT TO' unless parts[1] == '@'
          
          uname = parts[0]
          domain = parts[2]
          return '501 Invalid RCPT TO' if domain.blank?

          uname, tag = uname.split('+', 2)

          if domain == Postal.config.dns.return_path || domain =~ /\A#{Regexp.escape(Postal.config.dns.custom_return_path_prefix)}\./
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

          elsif domain == Postal.config.dns.route_domain
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

          elsif @credential || @domain
            # Handle authenticated sending
            @state = :rcpt_to_received
            if @domain
              if @domain.owner.suspended?
                '535 Mail server has been suspended'
              else
                log "Added external address '#{rcpt_to}' for authenticated domain user"
                @recipients << [:credential, rcpt_to, @server]
                '250 OK'
              end
            else
              if @credential.server.suspended?
                '535 Mail server has been suspended'
              else
                log "Added external address '#{rcpt_to}'"
                @recipients << [:credential, rcpt_to, @credential.server]
                '250 OK'
              end
            end

          elsif route = Route.find_by_name_and_domain(uname, domain)
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

          else
            # Original IP authentication attempt...
            @credential = Credential.where(type: 'SMTP-IP').all.sort_by { |c|
              c.ipaddr&.prefix || 0
            }.reverse.find { |credential|
              credential.ipaddr.include?(@ip_address)
            }

            if @credential
              @credential.use
              rcpt_to(data)
            else
              '530 Authentication required'
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

        if @headers['received'].select { |r| r =~ /by #{Postal.config.dns.smtp_server_hostname}/ }.count > 4
          transaction_reset
          @state = :welcomed
          return '550 Loop detected'
        end

        authenticated_domain = nil
        if @credential
          authenticated_domain = @credential.server.find_authenticated_domain_from_headers(@headers)
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
    end
  end
end