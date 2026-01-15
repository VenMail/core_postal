class ReputationMonitorJob < Postal::Job
  # Enhanced spam monitoring with content similarity detection and AI analysis
  # Optimized for millions of messages with proper ActiveRecord queries
  SIMILARITY_THRESHOLD = 0.8
  SEND_COUNT_THRESHOLD = 100
  BOUNCE_RATE_THRESHOLD = 5.0
  TIME_WINDOW_HOURS = 24
  BATCH_SIZE = 1000
  MAX_CONTENT_LENGTH = 5000
  SIMILARITY_SAMPLE_SIZE = 100
  MAX_THREADS = 2  # Reduced for better stability
  MAX_MEMORY_GROUPS = 10000  # Memory limit for message groups
  AI_RETRY_ATTEMPTS = 3
  AI_RETRY_DELAY = 2.seconds
  WEBHOOK_TIMEOUT = 10.seconds
  THREAD_TIMEOUT = 30.seconds
  
  def perform
    Rails.logger.info "ReputationMonitorJob: Starting enhanced spam monitoring analysis"
    
    begin
      # Process credentials in batches with proper error handling
      Credential.where(hold: false).find_each(batch_size: 50) do |credential|
        monitor_credential_with_error_handling(credential)
      end
      
      # Run original reputation monitoring
      run_original_reputation_monitoring
      
      Rails.logger.info "ReputationMonitorJob: Completed enhanced spam monitoring analysis"
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Critical job failure: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise  # Re-raise critical failures
    end
  end
  
  private
  
  def monitor_credential_with_error_handling(credential)
    begin
      monitor_credential(credential)
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Error monitoring credential #{credential.id}: #{e.message}"
    end
  end
  
  def monitor_credential(credential)
    server = credential.server
    return if server.suspended?
    
    since_time = TIME_WINDOW_HOURS.hours.ago
    message_count = get_message_count(server, since_time)
    
    return if message_count < SEND_COUNT_THRESHOLD
    
    Rails.logger.info "ReputationMonitorJob: Processing #{message_count} messages for credential #{credential.id}"
    
    process_messages_in_batches(credential, server, since_time, message_count)
  end
  
  def get_message_count(server, since_time)
    # Use proper MessageDB count query
    result = server.message_db.select('messages', 
      where: {
        scope: 'outgoing',
        timestamp: { greater_than: since_time.to_f },
        spam: false
      },
      count: true  # FIXED: Use count parameter instead of select
    )
    
    result || 0
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Error counting messages: #{e.message}"
    0
  end
  
  def process_messages_in_batches(credential, server, since_time, total_count)
    return if total_count < SEND_COUNT_THRESHOLD
    
    # Efficient data structures with memory limits
    content_counter = Hash.new(0)
    message_samples = {}
    
    # Stream through messages in batches
    offset = 0
    processed_count = 0
    
    while offset < total_count
      messages = get_message_batch_offset(server, since_time, offset, BATCH_SIZE)
      break if messages.empty?
      
      messages.each do |message|
        processed_count += 1
        
        content_key = extract_content_key(message)
        next if content_key.blank?
        
        content_counter[content_key] += 1
        
        # Store sample for groups that could reach threshold
        if content_counter[content_key] == 1
          # Memory protection: limit stored groups
          if message_samples.size < MAX_MEMORY_GROUPS
            message_samples[content_key] = {
              sample_message: message,
              message_ids: [message.id],
              count: 1
            }
          end
        elsif message_samples[content_key]
          message_samples[content_key][:count] += 1
          message_samples[content_key][:message_ids] << message.id
        end
      end
      
      offset += messages.size
      
      # Log progress periodically
      if processed_count % 5000 == 0
        Rails.logger.debug "ReputationMonitorJob: Processed #{processed_count}/#{total_count} messages"
        # Force garbage collection periodically
        GC.start if processed_count % 10000 == 0
      end
    end
    
    # Filter groups that meet threshold
    potential_spam_groups = message_samples.select { |_, data| data[:count] >= SEND_COUNT_THRESHOLD }
    
    Rails.logger.info "ReputationMonitorJob: Found #{potential_spam_groups.size} potential spam groups"
    
    # Analyze groups with thread pool
    analyze_spam_groups_threaded(credential, server, potential_spam_groups)
    
    # Cleanup memory
    message_samples.clear
    content_counter.clear
  end
  
  def get_message_batch_offset(server, since_time, offset, limit)
    server.message_db.select('messages',
      where: {
        scope: 'outgoing',
        timestamp: { greater_than: since_time.to_f },
        spam: false
      },
      order: :timestamp,
      direction: 'desc',
      limit: limit,
      offset: offset
    ).map { |record| Postal::MessageDB::Message.new(server.message_db, record) }
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Error getting message batch: #{e.message}"
    []
  end
  
  def extract_content_key(message)
    # Fast content key extraction with stable hash
    begin
      subject = extract_subject(message)
      body_sample = extract_body_sample(message)
      
      return nil if subject.blank? && body_sample.blank?
      
      # Use Digest for stable, collision-resistant hash
      content = "#{subject}|#{body_sample}"
      Digest::MD5.hexdigest(content)
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Content extraction failed for message #{message.id}: #{e.message}"
      nil
    end
  end
  
  # Pre-compiled regex patterns for better performance
  SUBJECT_REGEX = /^Subject:\s*(.+)$/mi.freeze
  HTML_TAG_REGEX = /<[^>]*>/.freeze
  NORMALIZATION_REGEX = /\d+|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|https?:\/\/\S+/i.freeze
  WHITESPACE_REGEX = /\s+/.freeze
  
  def extract_subject(message)
    return "" unless message.raw_headers
    
    # Use pre-compiled regex for better performance
    match = message.raw_headers.match(SUBJECT_REGEX)
    match ? match[1].strip.downcase[0, 50] : ""
  rescue
    ""
  end
  
  def extract_body_sample(message)
    return "" unless message.raw_body
    
    # Take first 200 chars, strip HTML with pre-compiled regex
    body = message.raw_body[0, 200]
    body.gsub(HTML_TAG_REGEX, ' ').strip.downcase[0, 100]
  rescue
    ""
  end
  
  def analyze_spam_groups_threaded(credential, server, spam_groups)
    return if spam_groups.empty?
    
    # Use concurrent-ruby thread pool for controlled concurrency
    require 'concurrent'
    
    pool = Concurrent::FixedThreadPool.new(MAX_THREADS)
    results = Concurrent::Array.new
    mutex = Mutex.new  # Thread safety for shared resources
    
    spam_groups.each do |content_key, group_data|
      pool.post do
        begin
          # FIXED: Pass server_id instead of server object to avoid thread safety issues
          server_id = server.id
          message_ids = group_data[:message_ids]
          
          ActiveRecord::Base.connection_pool.with_connection do
            # Re-fetch server in this thread's context
            thread_server = Server.find(server_id)
            bounce_rate = calculate_group_bounce_rate_optimized(thread_server.message_db, message_ids)
            
            # Thread-safe result collection
            mutex.synchronize do
              results << {
                group_data: group_data,
                bounce_rate: bounce_rate
              }
            end
          end
        rescue => e
          Rails.logger.error "ReputationMonitorJob: Error in threaded analysis: #{e.message}"
        end
      end
    end
    
    # Wait for all tasks to complete with timeout
    pool.shutdown
    unless pool.wait_for_termination(THREAD_TIMEOUT)
      Rails.logger.warn "ReputationMonitorJob: Thread pool timeout, forcing shutdown"
      pool.kill
    end
    
    # Process results sequentially to avoid race conditions
    results.each do |result|
      group_data = result[:group_data]
      bounce_rate = result[:bounce_rate]
      
      if bounce_rate >= BOUNCE_RATE_THRESHOLD
        perform_ai_analysis(credential, server, group_data, bounce_rate)
      end
    end
  end
  
  def calculate_group_bounce_rate_optimized(server, message_ids)
    return 0.0 if message_ids.empty?
    
    # FIXED: Use count parameter instead of select
    bounced_count = server.message_db.select('deliveries',
      where: {
        message_id: message_ids,
        status: 'Bounced'
      },
      count: true
    )
    
    bounced_total = bounced_count || 0
    (bounced_total.to_f / message_ids.size) * 100.0
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Optimized bounce check failed: #{e.message}"
    0.0
  end
  
  def calculate_group_bounce_rate(server, message_ids)
    return 0.0 if message_ids.empty?
    
    total_bounced = 0
    
    # Process in batches with proper MessageDB count queries
    message_ids.each_slice(500) do |id_batch|
      begin
        # FIXED: Use count parameter instead of select
        bounced_deliveries = server.message_db.count('deliveries',
          where: {
            message_id: id_batch,
            status: 'Bounced'
          }
        )
        
        total_bounced += bounced_deliveries if bounced_deliveries
      rescue => e
        Rails.logger.error "ReputationMonitorJob: Bounce check failed: #{e.message}"
      end
    end
    
    (total_bounced.to_f / message_ids.size) * 100.0
  end
  
  def perform_ai_analysis(credential, server, group_data, bounce_rate)
    sample_message = group_data[:sample_message]
    
    # Extract content with size limits
    content = extract_content_for_ai(sample_message)
    
    # FIXED: Use stable cache key with proper digest
    cache_key = "ai_analysis:#{Digest::MD5.hexdigest(content)}"
    ai_result = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      # ENHANCED: Pass actual sent count to API for better analysis
      call_venmail_ai_service(content, sample_message, group_data[:count])
    end
    
    if ai_result
      spam_probability = ai_result['spam_probability'].to_f
      
      if spam_probability >= 0.7
        suspend_credential(credential, server, group_data, bounce_rate, ai_result)
      elsif spam_probability >= 0.5
        log_spam_warning(credential, server, group_data, bounce_rate, ai_result)
      end
    end
  rescue => e
    Rails.logger.error "ReputationMonitorJob: AI analysis failed: #{e.message}"
  end
  
  def extract_content_for_ai(message)
    content_parts = []
    
    begin
      # Get subject
      subject = extract_subject(message)
      content_parts << subject if subject.present?
      
      # Get body with size limit
      if message.raw_body
        body_content = message.raw_body[0, 3000]
        stripped_body = body_content.gsub(HTML_TAG_REGEX, ' ')[0, 2000]
        content_parts << stripped_body.strip if stripped_body.present?
      end
      
      # Normalize with pre-compiled regex patterns and sanitize PII
      content = content_parts.join(' ').downcase
      content.gsub!(NORMALIZATION_REGEX) do |match|
        case match
        when /^\d+$/ then 'N'
        when /@/ then 'E'
        else 'U'
        end
      end
      content.gsub!(WHITESPACE_REGEX, ' ')
      
      # Additional security: Remove potential sensitive patterns
      content.gsub!(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/, 'CARD')  # Credit card patterns
      content.gsub!(/\b\d{3}-?\d{2}-?\d{4}\b/, 'SSN')  # SSN patterns
      
      content.strip[0, 4000]
      
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Content extraction failed: #{e.message}"
      ""
    end
  end
  
  def call_venmail_ai_service(content, message, sent_count = 1)
    # Use persistent connection with proper timeout handling and retry logic
    uri = URI('https://m.venmail.io/api/v1/analyze-outgoing')
    
    # FIXED: Match PHP API expected parameters
    payload = {
      content: content,
      sender: sanitize_email_address(message.mail_from),  # API expects 'sender' not 'from'
      subject: extract_subject(message)[0, 255],  # API limit is 255 chars
      sent_count: sent_count  # ENHANCED: Pass actual sent count for better analysis
    }
    
    attempt = 0
    
    AI_RETRY_ATTEMPTS.times do
      attempt += 1
      
      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 8
        http.open_timeout = 4
        
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['User-Agent'] = 'Postal-ReputationMonitor/3.0'
        request.body = payload.to_json
        
        response = http.request(request)
        
        if response.code.to_i == 200
          result = JSON.parse(response.body)
          
          # FIXED: Validate PHP API response structure
          if result.is_a?(Hash) && result['spam_probability']
            # Ensure spam_probability is in valid range
            spam_prob = result['spam_probability'].to_f
            spam_prob = [0.0, [1.0, spam_prob].min].max  # Clamp to 0.0-1.0
            
            return {
              'spam_probability' => spam_prob,
              'reason' => result['reason'] || 'AI analysis',
              'provider' => result['provider'] || 'unknown'
            }
          else
            Rails.logger.warn "ReputationMonitorJob: Invalid API response structure: #{result.keys}"
            return nil
          end
        elsif response.code.to_i == 400
          # FIXED: Handle validation errors from PHP API
          begin
            error_data = JSON.parse(response.body)
            Rails.logger.error "ReputationMonitorJob: API validation error: #{error_data['error']} - #{error_data['details']}"
          rescue
            Rails.logger.error "ReputationMonitorJob: API validation error: #{response.body}"
          end
          return nil
        elsif response.code.to_i == 503
          Rails.logger.error "ReputationMonitorJob: Spam detection service temporarily unavailable"
          return nil
        else
          Rails.logger.warn "ReputationMonitorJob: API returned #{response.code} on attempt #{attempt}: #{response.body}"
          
          # Don't retry on client errors (4xx)
          if response.code.to_i >= 400 && response.code.to_i < 500
            return nil
          end
        end
        
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Rails.logger.warn "ReputationMonitorJob: API timeout on attempt #{attempt}: #{e.message}"
      rescue JSON::ParserError => e
        Rails.logger.error "ReputationMonitorJob: Invalid JSON from API on attempt #{attempt}: #{e.message}"
        return nil  # Don't retry JSON parsing errors
      rescue => e
        Rails.logger.error "ReputationMonitorJob: API call failed on attempt #{attempt}: #{e.message}"
      ensure
        http&.finish if http&.started?
      end
      
      # Wait before retry (exponential backoff)
      if attempt < AI_RETRY_ATTEMPTS
        sleep(AI_RETRY_DELAY * (2 ** (attempt - 1)))
      end
    end
    
    Rails.logger.error "ReputationMonitorJob: API failed after #{AI_RETRY_ATTEMPTS} attempts"
    nil
  end
  
  def sanitize_email_address(email)
    return "" unless email.is_a?(String)
    # Extract domain only for privacy
    parts = email.split('@')
    if parts.size == 2
      "user@#{parts[1].downcase}"
    else
      "unknown"
    end
  rescue
    "unknown"
  end
  
  def suspend_credential(credential, server, group_data, bounce_rate, ai_result)
    reason = "Smart spam detection: #{group_data[:count]} similar emails, #{bounce_rate.round(2)}% bounce rate, AI: #{ai_result['spam_probability']}"
    
    credential.update!(hold: true)
    
    WebhookRequest.trigger(
      server,
      'CredentialLocked',
      {
        server: server.webhook_hash,
        credential: {
          id: credential.id,
          uuid: credential.uuid,
          name: credential.name,
          type: credential.type
        },
        reason: reason,
        spam_analysis: {
          message_count: group_data[:count],
          bounce_rate: bounce_rate,
          ai_spam_probability: ai_result['spam_probability']
        }
      }
    )
    
    Rails.logger.warn "ReputationMonitorJob: Suspended credential #{credential.uuid} - #{reason}"
    
    # Check for server suspension
    if bounce_rate >= 10.0 || ai_result['spam_probability'].to_f >= 0.9
      consider_server_suspension(server, credential, group_data, bounce_rate, ai_result)
    end
  end
  
  def log_spam_warning(credential, server, group_data, bounce_rate, ai_result)
    Rails.logger.warn "ReputationMonitorJob: Spam warning - #{credential.uuid}: #{group_data[:count]} emails, #{bounce_rate.round(2)}% bounce, AI: #{ai_result['spam_probability']}"
  end
  
  def consider_server_suspension(server, credential, group_data, bounce_rate, ai_result)
    # FIXED: Use transaction to prevent race condition
    ActiveRecord::Base.transaction do
      total_credentials = server.credentials.count
      problematic_credentials = server.credentials.where(hold: true).count
      
      if problematic_credentials >= 2 || (total_credentials > 0 && problematic_credentials.to_f / total_credentials >= 0.5)
        reason = "Multiple spam violations. Latest: #{group_data[:count]} emails, #{bounce_rate.round(2)}% bounce, AI: #{ai_result['spam_probability']}"
        server.suspend(reason)
        
        Rails.logger.error "ReputationMonitorJob: Suspended server #{server.permalink} - #{reason}"
      end
    end
  end
  
  def run_original_reputation_monitoring
    threshold = (Postal.config.general.reputation_block_threshold_percent || 3.0).to_f
    credential_threshold = (Postal.config.general.reputation_credential_bounce_threshold_percent || 8.0).to_f
    min_sample = (Postal.config.general.reputation_min_sample_size || 500).to_i

    Server.where(suspended_at: nil).find_each(batch_size: 50) do |server|
      begin
        stats = server.message_db.statistics.get(:daily, [:outgoing, :bounces, :spam], Time.now, 1)
        totals = stats.first ? stats.first[1] : { outgoing: 0, bounces: 0, spam: 0 }
        outgoing = totals[:outgoing].to_f
        bounces = totals[:bounces].to_f
        spam = totals[:spam].to_f

        next if outgoing < min_sample

        bounce_pct = outgoing.zero? ? 0.0 : (bounces / outgoing) * 100.0
        spam_pct = outgoing.zero? ? 0.0 : (spam / outgoing) * 100.0

        if bounce_pct >= credential_threshold
          server.credentials.where(hold: false).find_each(batch_size: 20) do |cred|
            cred.update(hold: true)
            WebhookRequest.trigger(
              server,
              'CredentialLocked',
              {
                server: server.webhook_hash,
                credential: { id: cred.id, uuid: cred.uuid, name: cred.name, type: cred.type },
                reason: "Bounce rate high (#{bounce_pct.round(2)}% >= #{credential_threshold}%)"
              }
            )
          end
        end

        if bounce_pct >= threshold || spam_pct >= threshold
          reason = "Reputation threshold exceeded (bounces=#{bounce_pct.round(2)}%, spam=#{spam_pct.round(2)}%, threshold=#{threshold}%)"
          server.suspend(reason)
        end
      rescue => e
        Rails.logger.error "ReputationMonitorJob: Error in original reputation monitoring for server #{server.id}: #{e.message}"
      end
    end
  end
end