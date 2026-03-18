class ReputationMonitorJob < Postal::Job
  # Optimized reputation monitoring with single-pass message processing
  # Eliminates redundant scans and N+1 queries for millions of messages
  
  # Consolidated constants
  TIME_WINDOW_HOURS = 24
  SEND_COUNT_THRESHOLD = 100
  BOUNCE_RATE_THRESHOLD = 5.0
  SERVER_SUSPENSION_THRESHOLD = 10.0
  AI_SPAM_THRESHOLD = 0.7
  AI_WARNING_THRESHOLD = 0.5
  
  # Performance tuning
  BATCH_SIZE = 1000
  MAX_MEMORY_GROUPS = 5000
  CREDENTIAL_BATCH_SIZE = 50
  MAX_MESSAGE_ITERATIONS = 1000  # Prevent infinite loops
  MAX_CREDENTIALS_PER_RUN = 100  # Keep each job bounded in time
  
  # Content processing limits
  SUBJECT_MAX_LENGTH = 100
  BODY_SAMPLE_LENGTH = 300
  AI_CONTENT_MAX_LENGTH = 2000
  
  # Reset configuration
  RESET_DAYS = 7
  RESET_THRESHOLD = 2.0
  
  # Pre-compiled regex patterns (frozen for performance)
  SUBJECT_REGEX = /^Subject:\s*(.+)$/mi.freeze
  HTML_TAG_REGEX = /<[^>]*>/.freeze
  DIGITS_REGEX = /\d+/.freeze
  EMAIL_REGEX = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i.freeze
  URL_REGEX = /https?:\/\/\S+/i.freeze
  WHITESPACE_REGEX = /\s+/.freeze
  
  def perform
    Rails.logger.info "ReputationMonitorJob: Starting optimized analysis"

    processed_credentials = 0
    Credential.where(hold: false).find_each(batch_size: CREDENTIAL_BATCH_SIZE) do |credential|
      monitor_credential_optimized(credential)
      processed_credentials += 1
      break if processed_credentials >= MAX_CREDENTIALS_PER_RUN
    end
    
    # Process credential resets
    reset_eligible_credentials
    
    Rails.logger.info "ReputationMonitorJob: Completed optimized analysis (processed #{processed_credentials} credentials)"
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Critical failure: #{e.message}"
    raise
  end
  
  private
  
  def monitor_credential_optimized(credential)
    server = credential.server
    return if server.suspended_at.present?
    
    since_time = TIME_WINDOW_HOURS.hours.ago
    
    # Single-pass message processing with grouping and bounce calculation
    message_groups = process_messages_single_pass(server, since_time)
    
    return if message_groups.empty?
    
    # Analyze only groups meeting threshold
    analyze_spam_groups_optimized(credential, server, message_groups)
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Error monitoring credential #{credential.id}: #{e.message}"
  end
  
  def process_messages_single_pass(server, since_time)
    message_groups = {}
    processed_count = 0
    
    # Single database query with streaming
    query_params = {
      where: {
        scope: 'outgoing',
        timestamp: { greater_than: since_time.to_f },
        spam: false
      },
      order: :timestamp,
      direction: 'desc'
    }
    
    offset = 0
    iterations = 0
    loop do
      break if iterations >= MAX_MESSAGE_ITERATIONS  # Breaks at 1000
      iterations += 1
      
      messages = server.message_db.select('messages', query_params.merge(limit: BATCH_SIZE, offset: offset))
      break if messages.empty?
      
      messages.each do |record|
        message = Postal::MessageDB::Message.new(server.message_db, record)
        processed_count += 1
        
        # Extract content once per message
        content_data = extract_content_data_optimized(message)
        next if content_data[:key].blank?
        
        # Initialize group if needed
        unless message_groups[content_data[:key]]
          if message_groups.size >= MAX_MEMORY_GROUPS
            Rails.logger.warn "ReputationMonitorJob: Reached max group limit (#{MAX_MEMORY_GROUPS}), " \
                          "stopping message processing for server #{server.id}"
            break  # Stop processing this server entirely
          end
          
          message_groups[content_data[:key]] = {
            count: 0,
            sample_message_id: message.id,
            sample_subject: content_data[:subject],
            sample_body: content_data[:body],
            sample_sender: extract_sender_from_message(message),
            bounced_count: 0
          }
        end
        
        # Update group
        group = message_groups[content_data[:key]]
        group[:count] += 1
        
        # Check delivery status in same pass
        if message.status == 'Bounced'
          group[:bounced_count] += 1
        end
      end
      
      offset += BATCH_SIZE
      
      # Log progress efficiently
      if processed_count % 10000 == 0
        Rails.logger.debug "ReputationMonitorJob: Processed #{processed_count} messages"
      end
    end
    
    # Filter groups meeting threshold
    message_groups.select { |_, data| data[:count] >= SEND_COUNT_THRESHOLD }
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Message processing failed for server #{server.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    raise # Re-raise to prevent silent failures
  end
  
  def extract_content_data_optimized(message)
    begin
      # Extract subject once
      subject = ""
      if message.raw_headers
        match = message.raw_headers.match(SUBJECT_REGEX)
        subject = match ? match[1].strip.downcase[0, SUBJECT_MAX_LENGTH] : ""
      end
      
      # Extract body once with HTML stripping
      body = ""
      if message.raw_body
        body_sample = message.raw_body[0, BODY_SAMPLE_LENGTH]
        body = body_sample.gsub(HTML_TAG_REGEX, ' ').strip.downcase
      end
      
      return { key: nil, subject: "", body: "" } if subject.blank? && body.blank?
      
      # Generate content key and fingerprint in single operation
      content = "#{subject}|#{body}"
      content_hash = Digest::MD5.hexdigest(content)
      
      {
        key: content_hash,
        subject: subject,
        body: body
      }
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Content extraction failed for message #{message.id}: #{e.message}"
      { key: nil, subject: "", body: "" }
    end
  end
  
  def extract_sender_from_message(message)
    begin
      # Extract sender from 'From' header
      if message.raw_headers
        from_match = message.raw_headers.match(/^From:\s*(.+)$/mi)
        if from_match
          from_address = from_match[1].strip
          # Extract email address from "Name <email@domain.com>" format
          email_match = from_address.match(EMAIL_REGEX)
          return email_match ? email_match[0].downcase : from_address.downcase
        end
      end
      
      # Fallback to mail_from if available
      message.mail_from&.downcase || "unknown@unknown.com"
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Sender extraction failed for message #{message.id}: #{e.message}"
      "unknown@unknown.com"
    end
  end
  
  def analyze_spam_groups_optimized(credential, server, message_groups)
    message_groups.each do |content_key, group_data|
      begin
        # Calculate bounce rate from pre-counted data (no additional queries)
        bounce_rate = group_data[:count] > 0 ? 
          (group_data[:bounced_count].to_f / group_data[:count]) * 100.0 : 0.0
        
        if bounce_rate >= BOUNCE_RATE_THRESHOLD
          perform_ai_analysis_optimized(credential, server, group_data, bounce_rate)
        end
      rescue => e
        Rails.logger.error "ReputationMonitorJob: Group analysis failed for group #{content_key} (credential #{credential.id}, server #{server.id}): #{e.message}\n#{e.backtrace.first(3).join("\n")}"
      end
    end
  end
  
  def perform_ai_analysis_optimized(credential, server, group_data, bounce_rate)
    # Use cached content data, no additional message fetch
    content = prepare_ai_content_optimized(group_data)
    return if content.blank?
    
    # Cache AI results
    cache_key = "ai_analysis:#{credential.id}:#{Digest::MD5.hexdigest(group_data[:sample_subject] + group_data[:sample_body])}"
    ai_result = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      call_venmail_ai_service_optimized(content, group_data, credential)
    end
    
    return unless ai_result&.dig('spam_probability')
    
    spam_probability = ai_result['spam_probability'].to_f
    
    if spam_probability >= AI_SPAM_THRESHOLD
      suspend_credential_optimized(credential, server, group_data, bounce_rate, ai_result)
    elsif spam_probability >= AI_WARNING_THRESHOLD
      log_spam_warning_optimized(credential, server, group_data, bounce_rate, ai_result)
    end
  rescue => e
    Rails.logger.error "ReputationMonitorJob: AI analysis failed for credential #{credential.id}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  end
  
  def prepare_ai_content_optimized(group_data)
    # Use pre-extracted content, no additional processing
    content_parts = []
    content_parts << group_data[:sample_subject] if group_data[:sample_subject].present?
    content_parts << group_data[:sample_body] if group_data[:sample_body].present?
    
    return "" if content_parts.empty?
    
    content = content_parts.join(' ').downcase
    
    # Remove sensitive data BEFORE normalization
    content = content.gsub(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/, '[CARD]')
                   .gsub(/\b\d{3}-?\d{2}-?\d{4}\b/, '[SSN]')
                   .gsub(EMAIL_REGEX, '[EMAIL]')
                   .gsub(URL_REGEX, '[URL]')
                   .gsub(DIGITS_REGEX, 'N')
                   .gsub(WHITESPACE_REGEX, ' ')
    
    content.strip[0, AI_CONTENT_MAX_LENGTH]
  end
  
  def call_venmail_ai_service_optimized(content, group_data, credential)
    uri = URI('https://m.venmail.io/api/v1/spam-check')
    
    # Validate inputs
    safe_subject = (group_data[:sample_subject] || "")[0, 255].strip
    
    payload = {
      content: content,
      sender: group_data[:sample_sender] || "unknown@unknown.com",
      subject: safe_subject,
      sent_count: group_data[:count] || 0
    }
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.read_timeout = 8
    http.open_timeout = 4
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = 'Postal-ReputationMonitor/4.0'
    request.body = payload.to_json
    
    response = http.request(request)
    
    if response.code.to_i == 200
      result = JSON.parse(response.body)
      if result.is_a?(Hash) && result['spam_probability']
        spam_prob = [[0.0, result['spam_probability'].to_f].max, 1.0].min
        return {
          'spam_probability' => spam_prob,
          'reason' => result['reason'] || 'AI analysis',
          'provider' => result['provider'] || 'unknown'
        }
      end
    end
    
    nil
  rescue => e
    Rails.logger.error "ReputationMonitorJob: API call failed for credential #{credential.id}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    nil
  end
  
  def suspend_credential_optimized(credential, server, group_data, bounce_rate, ai_result)
    reason = "Smart spam detection: #{group_data[:count]} similar emails, " \
             "#{bounce_rate.round(2)}% bounce rate, AI: #{ai_result['spam_probability']}"
    
    Credential.transaction do
      # Lock row for update to prevent race conditions
      cred = Credential.lock.find(credential.id)
      return if cred.hold  # Already suspended by another process
      
      cred.update!(
        hold: true,
        hold_at: Time.now,
        hold_reason: reason
      )
      
      WebhookRequest.trigger(
        server,
        'CredentialLocked',
        build_webhook_payload(server, cred, reason, {
          message_count: group_data[:count],
          bounce_rate: bounce_rate,
          ai_spam_probability: ai_result['spam_probability']
        })
      )
      
      Rails.logger.warn "ReputationMonitorJob: Suspended credential #{cred.uuid} - #{reason}"
      
      # Check server suspension with fresh data (outside transaction)
      if bounce_rate >= SERVER_SUSPENSION_THRESHOLD || ai_result['spam_probability'].to_f >= 0.9
        consider_server_suspension_optimized(server, group_data, bounce_rate, ai_result)
      end
    end
  rescue ActiveRecord::RecordNotFound
    Rails.logger.error "ReputationMonitorJob: Credential #{credential.id} not found during suspension"
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Credential suspension failed: #{e.message}"
  end
  
  def consider_server_suspension_optimized(server, group_data, bounce_rate, ai_result)
    # Use single query to avoid race conditions
    credential_stats = server.credentials.group(:hold).count
    problematic_count = credential_stats[true] || 0
    total_count = credential_stats.values.sum
    
    if problematic_count >= 2 || (total_count > 0 && problematic_count.to_f / total_count >= 0.5)
      reason = "Multiple spam violations. Latest: #{group_data[:count]} emails, #{bounce_rate.round(2)}% bounce, AI: #{ai_result['spam_probability']}"
      server.update!(suspended_at: Time.now, suspension_reason: reason)
      Rails.logger.error "ReputationMonitorJob: Suspended server #{server.permalink} - #{reason}"
    end
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Server suspension failed: #{e.message}"
  end
  
  def log_spam_warning_optimized(credential, server, group_data, bounce_rate, ai_result)
    Rails.logger.warn "ReputationMonitorJob: Spam warning - #{credential.uuid}: #{group_data[:count]} emails, #{bounce_rate.round(2)}% bounce, AI: #{ai_result['spam_probability']}"
  end
  
  def build_webhook_payload(server, credential, reason, analysis_data = {})
    {
      server: server.webhook_hash,
      credential: {
        id: credential.id,
        uuid: credential.uuid,
        name: credential.name,
        type: credential.type
      },
      reason: reason,
      spam_analysis: analysis_data
    }
  end
  
  def reset_eligible_credentials
    cutoff_time = RESET_DAYS.days.ago
    
    # Group by server to batch stats queries and prevent N+1
    held_credentials = Credential.where(hold: true)
                                 .where('hold_at < ?', cutoff_time)
                                 .includes(:server)
                                 .group_by(&:server)
    
    held_credentials.each do |server, credentials|
      next if server.suspended_at.present?
      
      # Single stats query per server
      current_bounce_rate = server.bounce_rate || 0.0
      next unless current_bounce_rate <= RESET_THRESHOLD
      
      min_sample = (Postal.config.general.reputation_min_sample_size || 50).to_i
      
      # Early exit if server has insufficient activity (avoid expensive query)
      if server.message_db.total_size < min_sample
        Rails.logger.debug "ReputationMonitorJob: Server #{server.id} has insufficient messages for reset (#{server.message_db.total_size} < #{min_sample})"
        next
      end
      
      stats = server.message_db.statistics.get(:daily, [:outgoing, :bounces], Time.now, 30)
      outgoing = stats.sum { |_, stat| stat[:outgoing].to_f }
      next unless outgoing >= min_sample
      
      # Reset all eligible credentials for this server
      credentials.each do |credential|
        reset_single_credential(server, credential, current_bounce_rate)
      end
    end
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Reset check failed: #{e.message}"
  end
  
  def reset_single_credential(server, credential, current_bounce_rate)
    Credential.transaction do
      credential.update!(hold: false, hold_at: nil, hold_reason: nil)
      
      WebhookRequest.trigger(
        server,
        'CredentialUnlocked',
        build_webhook_payload(server, credential, 
          "Bounce rate improved to #{current_bounce_rate.round(2)}% after #{RESET_DAYS} days",
          { bounce_rate: current_bounce_rate })
      )
    end
    
    Rails.logger.info "ReputationMonitorJob: Auto-unlocked credential #{credential.uuid}"
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Credential reset failed for #{credential.id}: #{e.message}"
  end
end
