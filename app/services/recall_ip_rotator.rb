class RecallIpRotator
  
  def initialize(server)
    @server = server
    @used_ips = Set.new
    @ip_health_cache = {}
  end
  
  def get_next_ip(exclude_primary: true)
    # Get all available IPs for this server's organization
    available_ips = @server.organization.ip_pools
      .flat_map(&:ip_addresses)
      .where(enabled: true)
    
    # Exclude primary IP if requested (to avoid potentially compromised IPs)
    if exclude_primary
      primary_ip = get_primary_ip_address
      available_ips = available_ips.where.not(id: primary_ip&.id) if primary_ip
    end
    
    # Exclude IPs we've already used in this recall session
    if @used_ips.any?
      available_ips = available_ips.where.not(id: @used_ips.to_a)
    end
    
    # Filter out IPs with poor reputation or recent failures
    healthy_ips = filter_healthy_ips(available_ips)
    
    # Select IP by priority and randomization
    selected_ip = healthy_ips.order_by_priority.select_by_priority
    
    if selected_ip
      @used_ips.add(selected_ip.id)
      Rails.logger.info("Selected IP #{selected_ip.ipv4} for recall operation")
      selected_ip
    else
      Rails.logger.warn("No healthy IPs available for recall operation, falling back to primary")
      get_primary_ip_address
    end
  end
  
  def reset_rotation
    @used_ips.clear
  end
  
  def mark_ip_failed(ip_address)
    # Mark IP as having recent failures
    cache_key = "ip_health_#{ip_address.id}"
    @ip_health_cache[cache_key] = {
      status: :failed,
      timestamp: Time.current,
      failure_count: (@ip_health_cache[cache_key]&.dig(:failure_count) || 0) + 1
    }
    Rails.logger.warn("Marked IP #{ip_address.ipv4} as failed (#{@ip_health_cache[cache_key][:failure_count]} failures)")
  end
  
  def mark_ip_success(ip_address)
    # Mark IP as successful (clears failure status)
    cache_key = "ip_health_#{ip_address.id}"
    @ip_health_cache.delete(cache_key)
  end
  
  private
  
  def filter_healthy_ips(ips)
    healthy_ips = []
    
    ips.each do |ip|
      cache_key = "ip_health_#{ip.id}"
      health = @ip_health_cache[cache_key]
      
      if health.nil?
        # No health data - assume healthy
        healthy_ips << ip
      elsif health[:status] == :failed
        # Check if enough time has passed to retry this IP
        retry_after = calculate_retry_delay(health[:failure_count])
        if Time.current - health[:timestamp] > retry_after
          healthy_ips << ip
          Rails.logger.info("IP #{ip.ipv4} is now eligible for retry after #{health[:failure_count]} failures")
        else
          Rails.logger.info("Skipping IP #{ip.ipv4} - still in cooldown period")
        end
      end
    end
    
    healthy_ips
  end
  
  def calculate_retry_delay(failure_count)
    # Exponential backoff: 5min, 15min, 30min, 1hr, 2hr, 4hr
    base_delay = 5.minutes
    [base_delay * (2 ** (failure_count - 1)), 4.hours].min
  end
  
  def get_primary_ip_address
    # Get the default or highest priority IP as primary
    @server.organization.ip_pools
      .flat_map(&:ip_addresses)
      .where(enabled: true)
      .order_by_priority
      .first
  end
  
end
