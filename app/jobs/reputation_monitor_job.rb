class ReputationMonitorJob < Postal::Job
  # Enhanced spam monitoring with content similarity detection and AI analysis
  # Optimized for millions of messages
  SIMILARITY_THRESHOLD = 0.8  # 80% similarity threshold
  SEND_COUNT_THRESHOLD = 100  # Minimum sends to trigger analysis
  BOUNCE_RATE_THRESHOLD = 5.0 # 5% bounce rate threshold
  TIME_WINDOW_HOURS = 24      # Analysis time window
  BATCH_SIZE = 1000           # Process messages in batches
  MAX_CONTENT_LENGTH = 5000   # Limit content length for performance
  SIMILARITY_SAMPLE_SIZE = 100 # Sample messages for similarity detection
  
  def perform
    Rails.logger.info "ReputationMonitorJob: Starting enhanced spam monitoring analysis"
    
    # Process credentials in batches to avoid memory issues
    Credential.where(hold: false).find_each(batch_size: 50) do |credential|
      begin
        monitor_credential(credential)
      rescue => e
        Rails.logger.error "ReputationMonitorJob: Error monitoring credential #{credential.id}: #{e.message}"
      end
    end
    
    # Also run the original reputation monitoring for backward compatibility
    run_original_reputation_monitoring
    
    Rails.logger.info "ReputationMonitorJob: Completed enhanced spam monitoring analysis"
  end
  
  private
  
  def monitor_credential(credential)
    server = credential.server
    return if server.suspended?
    
    # Get message count first to see if we should proceed
    since_time = TIME_WINDOW_HOURS.hours.ago
    message_count = get_message_count(server, since_time)
    
    return if message_count < SEND_COUNT_THRESHOLD
    
    Rails.logger.info "ReputationMonitorJob: Processing #{message_count} messages for credential #{credential.id}"
    
    # Process messages in batches to avoid memory issues
    process_messages_in_batches(credential, server, since_time, message_count)
  end
  
  def get_message_count(server, since_time)
    # Fast count query without loading message data
    count_result = server.message_db.select('messages', 
      where: {
        scope: 'outgoing',
        timestamp: { greater_than: since_time.to_f },
        spam: false
      },
      select: 'COUNT(*) as count'
    ).first
    
    count_result ? count_result['count'].to_i : 0
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Error counting messages: #{e.message}"
    0
  end
  
  def process_messages_in_batches(credential, server, since_time, total_count)
    # Pre-filter: only process if we have enough messages for potential spam
    return if total_count < SEND_COUNT_THRESHOLD
    
    # Use more efficient data structures
    content_counter = Hash.new(0)  # Faster than manual counting
    message_samples = {}           # Store only sample messages
    
    # Process all messages in streaming fashion (no pagination)
    offset = 0
    processed_count = 0
    
    while offset < total_count
      # Get smaller batches for better memory control
      messages = get_message_batch_offset(server, since_time, offset, BATCH_SIZE / 2)
      break if messages.empty?
      
      messages.each do |message|
        processed_count += 1
        
        # Fast content key extraction
        content_key = extract_content_key_fast(message)
        next if content_key.blank?
        
        # Increment counter efficiently
        content_counter[content_key] += 1
        
        # Store sample message only for first occurrence and if count could reach threshold
        if content_counter[content_key] == 1 && could_reach_threshold?(content_counter[content_key], total_count - processed_count)
          message_samples[content_key] = {
            sample_message: message,
            message_ids: [message.id],
            count: 1
          }
        elsif message_samples[content_key]
          message_samples[content_key][:count] += 1
          message_samples[content_key][:message_ids] << message.id
        end
      end
      
      offset += messages.size
      
      # More aggressive memory management
      if processed_count % 5000 == 0
        GC.start
        Rails.logger.debug "ReputationMonitorJob: Processed #{processed_count}/#{total_count} messages"
      end
    end
    
    # Filter and analyze only groups that meet threshold
    potential_spam_groups = message_samples.select { |_, data| data[:count] >= SEND_COUNT_THRESHOLD }
    
    Rails.logger.info "ReputationMonitorJob: Found #{potential_spam_groups.size} spam groups out of #{content_counter.size} content groups"
    
    # Analyze groups efficiently
    analyze_spam_groups_parallel(credential, server, potential_spam_groups)
  end
  
  def get_message_batch_offset(server, since_time, offset, limit)
    # Use offset/limit instead of pagination for better performance
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
  
  def could_reach_threshold?(current_count, remaining_messages)
    # Quick check if this content could potentially reach the threshold
    current_count + remaining_messages >= SEND_COUNT_THRESHOLD
  end
  
  def extract_content_key_fast(message)
    # Ultra-fast content key extraction with minimal processing
    begin
      # Use cached raw_headers/raw_body directly
      subject = extract_subject_fast(message)
      body_sample = extract_body_sample_fast(message)
      
      return nil if subject.blank? && body_sample.blank?
      
      # Create minimal hash key
      content = "#{subject}|#{body_sample}"
      content.hash.to_s  # Faster than MD5 for this use case
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Fast content extraction failed for message #{message.id}: #{e.message}"
      nil
    end
  end
  
  def extract_subject_fast(message)
    return "" unless message.raw_headers
    
    # Pre-compiled regex for better performance
    @subject_regex ||= /^Subject:\s*(.+)$/mi
    match = message.raw_headers.match(@subject_regex)
    match ? match[1].strip.downcase[0, 50] : ""
  rescue => e
    ""
  end
  
  def extract_body_sample_fast(message)
    return "" unless message.raw_body
    
    # Take first 200 chars only, minimal processing
    body = message.raw_body[0, 200]
    body.gsub(/<[^>]*>/, ' ').strip.downcase[0, 100]
  rescue => e
    ""
  end
  
  def analyze_spam_groups_parallel(credential, server, spam_groups)
    return if spam_groups.empty?
    
    # Process groups in parallel threads for better performance
    threads = []
    results = []
    semaphore = Mutex.new
    
    spam_groups.each_slice(5) do |group_slice|  # Process 5 groups per thread
      threads << Thread.new do
        begin
          group_slice.each do |content_key, group_data|
            # Calculate bounce rate efficiently
            bounce_rate = calculate_group_bounce_rate_optimized(server, group_data[:message_ids])
            
            semaphore.synchronize do
              results << {
                group_data: group_data,
                bounce_rate: bounce_rate
              }
            end
          end
        rescue => e
          Rails.logger.error "ReputationMonitorJob: Error in parallel analysis: #{e.message}"
        end
      end
    end
    
    # Wait for all threads to complete
    threads.each(&:join)
    
    # Process results
    results.each do |result|
      group_data = result[:group_data]
      bounce_rate = result[:bounce_rate]
      
      # Only AI analysis if bounce rate is high
      if bounce_rate >= BOUNCE_RATE_THRESHOLD
        perform_ai_analysis_optimized(credential, server, group_data, bounce_rate)
      end
    end
  end
  
  def calculate_group_bounce_rate_optimized(server, message_ids)
    return 0.0 if message_ids.empty?
    
    # Use a single optimized query with IN clause
    bounced_count = 0
    
    # Process in larger batches for fewer queries
    message_ids.each_slice(500) do |id_batch|
      begin
        # Single query to get all bounced deliveries
        bounced_deliveries = server.message_db.select('deliveries',
          where: 'message_id IN (?) AND status = ?', id_batch, 'Bounced',
          select: 'COUNT(DISTINCT message_id) as count'
        ).first
        
        bounced_count += bounced_deliveries['count'].to_i if bounced_deliveries
      rescue => e
        Rails.logger.error "ReputationMonitorJob: Optimized bounce check failed: #{e.message}"
      end
    end
    
    (bounced_count.to_f / message_ids.size) * 100.0
  end
  
  def perform_ai_analysis_optimized(credential, server, group_data, bounce_rate)
    sample_message = group_data[:sample_message]
    
    # Extract content with size limits
    content = extract_content_for_ai_optimized(sample_message)
    
    # Call AI service with caching
    cache_key = "ai_analysis:#{content.hash}"
    ai_result = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      call_venmail_ai_service_optimized(content, sample_message)
    end
    
    if ai_result
      spam_probability = ai_result['spam_probability'].to_f
      
      if spam_probability >= 0.7
        suspend_credential_optimized(credential, server, group_data, bounce_rate, ai_result)
      elsif spam_probability >= 0.5
        log_spam_warning_optimized(credential, server, group_data, bounce_rate, ai_result)
      end
    end
  rescue => e
    Rails.logger.error "ReputationMonitorJob: Optimized AI analysis failed: #{e.message}"
  end
  
  def extract_content_for_ai_optimized(message)
    # Optimized content extraction with pre-allocated strings
    content_parts = []
    
    begin
      # Get subject efficiently
      subject = extract_subject_fast(message)
      content_parts << subject if subject.present?
      
      # Get body with strict size limit
      if message.raw_body
        body_content = message.raw_body[0, 3000]  # Reduced limit
        # Minimal HTML processing
        stripped_body = body_content.gsub(/<[^>]*>/, ' ')[0, 2000]
        content_parts << stripped_body.strip if stripped_body.present?
      end
      
      # Fast normalization
      content = content_parts.join(' ').downcase
      content.gsub!(/\d+/, 'N')        # Shorter placeholder
      content.gsub!(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, 'E')  # Email placeholder
      content.gsub!(/https?:\/\/\S+/i, 'U')  # URL placeholder
      content.gsub!(/\s+/, ' ')
      content.strip[0, 4000]  # Final strict limit
      
    rescue => e
      Rails.logger.error "ReputationMonitorJob: Optimized content extraction failed: #{e.message}"
      ""
    end
  end
  
  def call_venmail_ai_service_optimized(content, message)
    # Optimized HTTP call with connection pooling
    uri = URI('https://m.venmail.io/api/v1/analyze-outgoing')
    
    payload = {
      content: content,
      subject: extract_subject_fast(message),
      from: message.mail_from,
      to: message.rcpt_to,
      timestamp: Time.now.iso8601
    }
    
    # Use persistent HTTP connection
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 8   # Reduced timeout
    http.open_timeout = 4   # Reduced timeout
    http.start  # Start connection for reuse
    
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['User-Agent'] = 'Postal-ReputationMonitor/3.0'
    request['Connection'] = 'keep-alive'
    
    request.body = payload.to_json
    
    response = http.request(request)
    http.finish if http.started?
    
    if response.code.to_i == 200
      JSON.parse(response.body)
    else
      Rails.logger.warn "ReputationMonitorJob: AI service returned #{response.code}"
      nil
    end
  rescue Net::TimeoutError => e
    Rails.logger.warn "ReputationMonitorJob: AI service timeout: #{e.message}"
    nil
  rescue => e
    Rails.logger.error "ReputationMonitorJob: AI service call failed: #{e.message}"
    nil
  ensure
    http.finish if http && http.started?
  end
  
  def suspend_credential_optimized(credential, server, group_data, bounce_rate, ai_result)
    reason = "Smart spam detection: #{group_data[:count]} similar emails, #{bounce_rate.round(2)}% bounce rate, AI: #{ai_result['spam_probability']}"
    
    credential.update!(hold: true)
    
    # Minimal webhook payload
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
    
    # Server suspension check
    if bounce_rate >= 10.0 || ai_result['spam_probability'].to_f >= 0.9
      consider_server_suspension_optimized(server, credential, group_data, bounce_rate, ai_result)
    end
  end
  
  def log_spam_warning_optimized(credential, server, group_data, bounce_rate, ai_result)
    Rails.logger.warn "ReputationMonitorJob: Spam warning - #{credential.uuid}: #{group_data[:count]} emails, #{bounce_rate.round(2)}% bounce, AI: #{ai_result['spam_probability']}"
  end
  
  def consider_server_suspension_optimized(server, credential, group_data, bounce_rate, ai_result)
    # Cached credential counts to avoid repeated queries
    @credential_counts ||= {}
    server_id = server.id
    
    unless @credential_counts[server_id]
      @credential_counts[server_id] = {
        total: server.credentials.count,
        problematic: server.credentials.where(hold: true).count
      }
    end
    
    counts = @credential_counts[server_id]
    
    if counts[:problematic] >= 2 || (counts[:total] > 0 && counts[:problematic].to_f / counts[:total] >= 0.5)
      reason = "Multiple spam violations. Latest: #{group_data[:count]} emails, #{bounce_rate.round(2)}% bounce, AI: #{ai_result['spam_probability']}"
      server.suspend(reason)
      
      Rails.logger.error "ReputationMonitorJob: Suspended server #{server.permalink} - #{reason}"
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
            cred.update(:hold => true)
            WebhookRequest.trigger(
              server,
              'CredentialLocked',
              {
                :server => server.webhook_hash,
                :credential => { :id => cred.id, :uuid => cred.uuid, :name => cred.name, :type => cred.type },
                :reason => "Bounce rate high (#{bounce_pct.round(2)}% >= #{credential_threshold}%)"
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
