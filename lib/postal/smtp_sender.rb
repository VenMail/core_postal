require 'resolv'

module Postal
  class SMTPSender < Sender

    def initialize(domain, source_ip_address, options = {})
      @domain = domain
      @source_ip_address = source_ip_address
      @options = options
      @smtp_client = nil
      @connection_errors = []
      @hostnames = []
      @log_id = Nifty::Utils::RandomString.generate(:length => 8).upcase
    end

    def start
      servers.each do |server|
        if server.is_a?(SMTPEndpoint)
          hostname = server.hostname
          port = server.port || 25
          ssl_mode = server.ssl_mode
        elsif server.is_a?(Hash)
          hostname = server[:hostname]
          port = server[:port] || 25
          ssl_mode = server[:ssl_mode] || 'Auto'
        else
          hostname = server
          port = 25
          ssl_mode = 'Auto'
        end

        @hostnames << hostname
        [:aaaa, :a].each do |ip_type|

          if @source_ip_address && @source_ip_address.ipv6.blank? && ip_type == :aaaa
            # Don't try to use IPv6 if the IP address we're sending from doesn't support it.
            next
          end

          begin
            @remote_ip = lookup_ip_address(ip_type, hostname)
            if @remote_ip.nil?
              if ip_type == :a
                # As we can't resolve the last IP, we'll put this
                @connection_errors << "Could not resolve #{hostname}"
              end
              next
            end

            smtp_client = Net::SMTP.new(hostname, port)
            smtp_client.open_timeout = Postal.config.smtp_client.open_timeout
            smtp_client.read_timeout = Postal.config.smtp_client.read_timeout

            if @source_ip_address
              # Set the source IP as appropriate
              smtp_client.source_address = ip_type == :aaaa ? @source_ip_address.ipv6 : @source_ip_address.ipv4
            end

            case ssl_mode
            when 'Auto'
              smtp_client.enable_starttls_auto(self.class.ssl_context_without_verify)
            when 'STARTTLS'
              smtp_client.enable_starttls(self.class.ssl_context_with_verify)
            when 'TLS'
              smtp_client.enable_tls(self.class.ssl_context_with_verify)
            else
              # Nothing
            end

            smtp_client.start(@source_ip_address ? @source_ip_address.hostname : self.class.default_helo_hostname)
            log "Connected to #{@remote_ip}:#{port} (#{hostname})"

          rescue => e
            if e.is_a?(OpenSSL::SSL::SSLError) && ssl_mode == 'Auto'
              log "SSL error (#{e.message}), retrying without SSL"
              ssl_mode = nil
              retry
            end

            log "Cannot connect to #{@remote_ip}:#{port} (#{hostname}) (#{e.class}: #{e.message})"
            @connection_errors << e.message unless @connection_errors.include?(e.message)
            smtp_client.disconnect rescue nil
            smtp_client = nil
          end

          if smtp_client
            @smtp_client = smtp_client
            return true
          end
        end
      end

      @connection_errors
    end

    def reconnect
      log "Reconnecting"
      @smtp_client&.finish rescue nil
      start
    end

    def safe_rset
      # Something went wrong sending the last email. Reset the connection if possible, else disconnect.
      begin
        @smtp_client.rset
      rescue
        # Don't reconnect, this would be rather rude if we don't have any more emails to send.
        @smtp_client.finish rescue nil
      end
    end

    def send_message(message, force_rcpt_to = nil)
      start_time = Time.now
      result = SendResult.new
      result.log_id = @log_id
      if @smtp_client && !@smtp_client.started?
        start
      end
    
      if @smtp_client
        result.secure = @smtp_client.secure_socket?
      end
    
      begin
        if Postal.config.smtp_server.disable_bounce_return_path
          if message.bounce == 1
            mail_from = ""
          else
            # Extract From header to determine MAIL FROM
            headers, _ = extract_headers_and_body(message.raw_message)
            from_header = headers.find { |h| h.downcase.start_with?('from:') }
            
            mail_from = if from_header
                          # Extract email address from From header
                          address_part = from_header.split(':', 2).last.strip
                          email = address_part[/<([^>]+)>/, 1] || address_part.split.find { |p| p.include?('@') }
                          email ? email.strip : ""
                        else
                          # Fallback to original MAIL FROM if no From header
                          message.mail_from
                        end
            
            log "Debug: Using sender address from From header: #{mail_from}"
          end
        else
          # Standard return path logic
          mail_from = message.domain.return_path_status == 'OK' ? 
            "#{message.server.token}@#{message.domain.return_path_domain}" : 
            "#{message.server.token}@#{Postal.config.dns.return_path}"
        end
        
        rcpt_to = force_rcpt_to || @options[:force_rcpt_to] || message.rcpt_to
        unless rcpt_to && rcpt_to.is_a?(String) && !rcpt_to.strip.empty?
          log "Error: Invalid recipient address: #{rcpt_to.inspect}"
          raise ArgumentError, "Invalid recipient address"
        end
        recipients = [rcpt_to.strip]
        
        # Debug logging
        log "Debug: Processing message #{message.id}, bounce=#{message.bounce}"
        
        # IMPORTANT: Never modify the raw message content - ever
        raw_message = message.raw_message
        
        log "Debug: Sending with envelope from: #{mail_from}"
        log "Debug: Raw message contains #{raw_message.scan(/^Resent-Sender:/i).count} Resent-Sender headers"
        
        # Log a sample of the message
        header_preview = raw_message.split(/\r?\n\r?\n/, 2)[0].split(/\r?\n/).first(10).join("\r\n")
        log "Debug: First 10 lines of headers:\r\n#{header_preview}"
        
        tries = 0
        begin
          if @smtp_client.nil?
            log "-> No SMTP server available for #{@domain}"
            result.type = 'SoftFail'
            result.retry = true
            result.details = "No SMTP servers were available for #{@domain}. Tried #{@hostnames.to_sentence}"
            result.output = @connection_errors.join(', ')
            result.connect_error = true
            return result
          else
            @smtp_client.rset_errors
            log "Sending message #{message.server.id}::#{message.id} using direct SMTP commands"
            @smtp_client.mailfrom(mail_from)
            recipients.each do |recipient|
              @smtp_client.rcptto(recipient)
            end
            smtp_result = @smtp_client.data(raw_message + "\r\n.\r\n")
          end
        rescue Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError
          if (tries += 1) < 2
            reconnect
            retry
          else
            raise
          end
        end
    
        result.type = 'Sent'
        result.details = "Message for #{rcpt_to} accepted by #{destination_host_description}"
        if @smtp_client.source_address
          result.details += " (from #{@smtp_client.source_address})"
        end
        result.output = smtp_result.string
        log "Message sent ##{message.id} to #{destination_host_description} for #{rcpt_to}"
    
      rescue Net::SMTPFatalError => e
        log "#{e.class}: #{e.message}"
        result.type = 'HardFail'
        result.details = "Permanent SMTP delivery error when sending to #{destination_host_description}"
        result.output = e.message
        safe_rset
      rescue Net::SMTPServerBusy, Net::SMTPAuthenticationError, Net::SMTPSyntaxError, Net::SMTPUnknownError, Net::ReadTimeout => e
        log "#{e.class}: #{e.message}"
        result.type = 'SoftFail'
        result.retry = true
        result.details = "Temporary SMTP delivery error when sending to #{destination_host_description}"
        result.output = e.message
        if e.to_s =~ /(\d+) seconds/
          result.retry = $1.to_i + 10
        elsif e.to_s =~ /(\d+) minutes/
          result.retry = ($1.to_i * 60) + 10
        end
        safe_rset
      rescue => e
        log "#{e.class}: #{e.message}"
        if defined?(Raven)
          Raven.capture_exception(e, :extra => {:log_id => @log_id, :server_id => message.server.id, :message_id => message.id})
        end
        result.type = 'SoftFail'
        result.retry = true
        result.details = "An error occurred while sending the message to #{destination_host_description}"
        result.output = e.message
        safe_rset
      end
    
      result.time = (Time.now - start_time).to_f.round(2)
      result
    end

    def finish
      log "Finishing up"
      @smtp_client&.finish
    end

    private

    def servers
      @options[:servers] || self.class.relay_hosts || @servers ||= begin
        mx_servers = MXLookup.lookup(@domain)
        if mx_servers.empty?
          mx_servers = [@domain] # This will be resolved to an A or AAAA record later
        end
        mx_servers
      end
    end

    def log(text)
      Postal.logger_for(:smtp_sender).info "[#{@log_id}] #{text}"
    end

    def destination_host_description
      "#{@hostnames.last} (#{@remote_ip})"
    end

    def lookup_ip_address(type, hostname)
      records = []
      Resolv::DNS.open do |dns|
        dns.timeouts = [10,5]
        case type
        when :a
          records = dns.getresources(hostname, Resolv::DNS::Resource::IN::A)
        when :aaaa
          records = dns.getresources(hostname, Resolv::DNS::Resource::IN::AAAA)
        end
      end
      records.first&.address&.to_s&.downcase
    end

    def self.ssl_context_with_verify
      @ssl_context_with_verify ||= begin
        c = OpenSSL::SSL::SSLContext.new
        c.verify_mode = OpenSSL::SSL::VERIFY_PEER
        c.cert_store = OpenSSL::X509::Store.new
        c.cert_store.set_default_paths
        c
      end
    end

    def self.ssl_context_without_verify
      @ssl_context_without_verify ||= begin
        c = OpenSSL::SSL::SSLContext.new
        c.verify_mode = OpenSSL::SSL::VERIFY_NONE
        c
      end
    end

    def self.default_helo_hostname
      Postal.config.dns.helo_hostname || Postal.config.dns.smtp_server_hostname || "localhost"
    end

    def self.relay_hosts
      hosts = Postal.config.smtp_relays.map do |relay|
        if relay.hostname.present?
          {
            :hostname => relay.hostname,
            :port => relay.port,
            :ssl_mode => relay.ssl_mode
          }
        else
          nil
        end
      end.compact
      hosts.empty? ? nil : hosts
    end

    def extract_headers_and_body(raw_message)
      parts = raw_message.split(/\r?\n\r?\n/, 2)
      headers = parts[0].split(/\r?\n/)
      body = parts.size > 1 ? parts[1] : ""
      [headers, body]
    end

  end
end
