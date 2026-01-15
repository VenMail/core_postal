class RecallNoticeJob < Postal::Job
  
  # Conservative rate limiting to avoid spam filters
  RATE_LIMIT_DELAY = 2.seconds          # 30 emails per minute max
  MAX_BATCH_SIZE = 10                   # Small batches
  BATCH_DELAY = 30.seconds              # Long delay between batches
  MAX_HOURLY_SEND = 500                 # Hourly sending limit
  
  # Spam protection thresholds
  MAX_DOMAIN_SEND_PER_HOUR = 50         # Per-domain limit
  LARGE_SEND_THRESHOLD = 100           # Triggers warm-up period
  WARM_UP_MULTIPLIER = 3               # Slower sending for large batches
  
  # IP rotation settings
  IP_ROTATION_FREQUENCY = 20           # Change IP every 20 emails
  PREFER_BACKUP_IPS = true             # Avoid primary IP for recalls
  
  def perform
    recipients = params['recipients']
    subject = params['subject']
    body = params['body']
    server_id = params['server_id']
    user_id = params['user_id']
    @server = Server.find(server_id)
    @user = User.find(user_id)
    @success_count = 0
    @failure_count = 0
    @domain_counts = Hash.new(0)
    @hourly_count = get_hourly_send_count
    @emails_sent_with_current_ip = 0
    @current_ip = nil
    
    # Initialize IP rotator
    @ip_rotator = RecallIpRotator.new(@server)
    
    # Check hourly sending limit
    if @hourly_count >= MAX_HOURLY_SEND
      Rails.logger.error("Hourly sending limit exceeded (#{@hourly_count}/#{MAX_HOURLY_SEND})")
      raise "Hourly sending limit exceeded"
    end
    
    # Adjust rate limiting for large sends
    if recipients.size > LARGE_SEND_THRESHOLD
      @rate_delay = RATE_LIMIT_DELAY * WARM_UP_MULTIPLIER
      @batch_delay = BATCH_DELAY * WARM_UP_MULTIPLIER
      Rails.logger.info("Large send detected (#{recipients.size}), using warm-up delays")
    else
      @rate_delay = RATE_LIMIT_DELAY
      @batch_delay = BATCH_DELAY
    end
    
    Rails.logger.info("Starting recall job for #{recipients.size} recipients on server #{@server.name}")
    
    # Group recipients by domain for monitoring
    domain_groups = recipients.group_by { |email| email.split('@').last.downcase }
    
    # Process recipients in small batches to avoid spam filters
    recipients.each_slice(MAX_BATCH_SIZE) do |batch|
      batch.each do |recipient|
        break if @hourly_count >= MAX_HOURLY_SEND
        
        # Rotate IP if needed
        rotate_ip_if_needed
        
        if send_recall_notice(recipient, subject, body)
          @success_count += 1
          @hourly_count += 1
          @emails_sent_with_current_ip += 1
        else
          @failure_count += 1
        end
        
        # Rate limiting delay between sends
        sleep(@rate_delay) if batch.size > 1
      end
      
      # Check if we should continue
      break if @hourly_count >= MAX_HOURLY_SEND
      
      # Longer delay between batches
      sleep(@batch_delay) unless batch == recipients.last(MAX_BATCH_SIZE)
      
      # Log progress and domain distribution
      log_progress_and_domains
    end
    
    Rails.logger.info("Recall job completed: #{@success_count} sent, #{@failure_count} failed")
  rescue => e
    Rails.logger.error("Recall job failed: #{e.class} #{e.message}\n#{e.backtrace.join("\n")}")
    raise
  end
  
  private
  
  def get_hourly_send_count
    # Count emails sent in the last hour from this server
    # This is a simple implementation - you may want to use Redis or database tracking
    Rails.cache.fetch("recall_hourly_count_#{@server.id}", expires_in: 1.hour) do
      # In production, track this in a proper database table
      0
    end
  end
  
  def increment_hourly_count
    current_count = Rails.cache.read("recall_hourly_count_#{@server.id}") || 0
    Rails.cache.write("recall_hourly_count_#{@server.id}", current_count + 1, expires_in: 1.hour)
  end
  
  def check_domain_limit(email)
    domain = email.split('@').last.downcase
    domain_key = "recall_domain_#{domain}_#{@server.id}"
    current_count = Rails.cache.read(domain_key) || 0
    
    if current_count >= MAX_DOMAIN_SEND_PER_HOUR
      Rails.logger.warn("Domain limit exceeded for #{domain}: #{current_count}/#{MAX_DOMAIN_SEND_PER_HOUR}")
      return false
    end
    
    Rails.cache.write(domain_key, current_count + 1, expires_in: 1.hour)
    @domain_counts[domain] += 1
    true
  end
  
  def log_progress_and_domains
    Rails.logger.info("Recall progress: #{@success_count} sent, #{@failure_count} failed")
    Rails.logger.info("Domain distribution: #{@domain_counts}")
    Rails.logger.info("Current IP: #{@current_ip&.ipv4} (#{@emails_sent_with_current_ip} emails sent)")
  end
  
  def rotate_ip_if_needed
    # Get initial IP or rotate after threshold
    if @current_ip.nil? || @emails_sent_with_current_ip >= IP_ROTATION_FREQUENCY
      @current_ip = @ip_rotator.get_next_ip(exclude_primary: PREFER_BACKUP_IPS)
      @emails_sent_with_current_ip = 0
      Rails.logger.info("Rotated to IP #{@current_ip&.ipv4} for recall operation")
    end
  end
  
  def send_recall_notice(recipient, subject, body)
    # Skip if recipient is on suppression list
    if @server.message_db.suppression_list.get(:recipient, recipient)
      Rails.logger.info("Skipped suppressed recipient: #{recipient}")
      return false
    end
    
    # Check domain-specific limits
    unless check_domain_limit(recipient)
      Rails.logger.info("Skipped due to domain limit: #{recipient}")
      return false
    end
    
    # Add small variations to avoid duplicate content filters
    varied_subject = add_content_variation(subject)
    varied_body = add_content_variation(body)
    
    # Create mail with custom SMTP settings for IP rotation
    mail = AppMailer.recall_notice(recipient, varied_subject, varied_body)
    
    # Override SMTP settings to use selected IP if available
    if @current_ip
      mail.delivery_method.settings = {
        address: Postal.config.smtp.host,
        port: Postal.config.smtp.port || 587,
        user_name: Postal.config.smtp.username,
        password: Postal.config.smtp.password,
        domain: @current_ip.hostname,
        enable_starttls_auto: true
      }
    end
    
    mail.deliver_now
    
    # Mark IP as successful
    @ip_rotator.mark_ip_success(@current_ip) if @current_ip
    
    increment_hourly_count
    Rails.logger.info("Recall notice sent to #{recipient} via IP #{@current_ip&.ipv4}")
    true
  rescue => e
    Rails.logger.error("Recall enqueue failed for #{recipient}: #{e.class} #{e.message}")
    
    # Mark IP as failed if it's a connection-related error
    if connection_related_error?(e)
      @ip_rotator.mark_ip_failed(@current_ip) if @current_ip
      Rails.logger.warn("Marked IP #{@current_ip&.ipv4} as failed due to connection error")
    end
    
    # Don't raise individual email errors - continue with other recipients
    false
  end
  
  def connection_related_error?(error)
    connection_errors = [
      'Errno::ECONNREFUSED',
      'Errno::ETIMEDOUT',
      'Net::SMTPAuthenticationError',
      'Net::SMTPServerBusy',
      'Net::SMTPFatalError',
      'Net::ReadTimeout',
      'Net::OpenTimeout'
    ]
    
    connection_errors.include?(error.class.name)
  end
  
  def add_content_variation(content)
    # Add subtle variations to avoid duplicate content detection
    variations = [
      " ",
      "\n",
      "  ",
      "\n\n"
    ]
    
    # Add a tiny random variation that won't affect readability
    variation = variations.sample
    if content.include?("\n")
      content.gsub(/\n/, "#{variation}\n")
    else
      "#{content}#{variation}"
    end
  end
end
