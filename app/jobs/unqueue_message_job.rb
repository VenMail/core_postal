class UnqueueMessageJob < Postal::Job
  def perform
    if original_message = QueuedMessage.find_by_id(params['id'])
      if original_message.acquire_lock

        log "Lock acquired for queued message #{original_message.id}"

        begin
          original_message.message
        rescue Postal::MessageDB::Message::NotFound
          log "Unqueue #{original_message.id} because backend message has been removed."
          original_message.destroy
          return
        end

        unless original_message.retriable?
          log "Skipping because retry after isn't reached"
          original_message.unlock
          return
        end

        begin
          other_messages = original_message.batchable_messages(100)
          log "Found #{other_messages.size} associated messages to process at the same time (batch key: #{original_message.batch_key})"
        rescue
          original_message.unlock
          raise
        end

        ([original_message] + other_messages).each do |queued_message|
          log_prefix = "[#{queued_message.server_id}::#{queued_message.message_id} #{queued_message.id}]"
          begin
            log "#{log_prefix} Got queued message with exclusive lock"
            log "#{log_prefix} Message properties: rcpt_to=#{queued_message.message.rcpt_to.inspect}"
            begin
              queued_message.message
            rescue Postal::MessageDB::Message::NotFound
              log "#{log_prefix} Unqueueing #{queued_message.id} because backend message has been removed"
              queued_message.destroy
              next
            end

            #
            # If the server is suspended, hold all messages
            #
            if queued_message.server.suspended?
              log "#{log_prefix} Server is suspended. Holding message."
              queued_message.message.create_delivery('Held', :details => "Mail server has been suspended. No e-mails can be processed at present. Contact support for assistance.")
              queued_message.destroy
              next
            end

            # We might not be able to send this any more, check the attempts
            if queued_message.attempts >= Postal.config.general.maximum_delivery_attempts
              details = "Maximum number of delivery attempts (#{queued_message.attempts}) has been reached."
              if queued_message.message.scope == 'incoming'
                # Send bounces to incoming e-mails when they are hard failed
                if bounce_id = queued_message.send_bounce
                  details += " Bounce sent to sender (see message <msg:#{bounce_id}>)"
                end
              elsif queued_message.message.scope == 'outgoing'
                # Add the recipient to the suppression list
                if queued_message.server.message_db.suppression_list.add(:recipient, queued_message.message.rcpt_to, :reason => "too many soft fails")
                  log "Added #{queued_message.message.rcpt_to} to suppression list because maximum attempts has been reached"
                  details += " Added #{queued_message.message.rcpt_to} to suppression list because delivery has failed #{queued_message.attempts} times."
                end
              end
              queued_message.message.create_delivery('HardFail', :details => details)
              queued_message.destroy
              log "#{log_prefix} Message has reached maximum number of attempts. Hard failing."
              next
            end

            # If the raw message has been removed (removed by retention)
            unless queued_message.message.raw_message?
              log "#{log_prefix} Raw message has been removed. Not sending."
              queued_message.message.create_delivery('HardFail', :details => "Raw message has been removed. Cannot send message.")
              queued_message.destroy
              next
            end

            #
            # Handle Incoming Messages
            #
            if queued_message.message.scope == 'incoming'
              #
              # If this is a bounce, we need to handle it as such
              #
              if queued_message.message.bounce == 1
                log "#{log_prefix} Message is a bounce"
                original_messages = queued_message.message.original_messages
                unless original_messages.empty?
                  for original_message in queued_message.message.original_messages
                    queued_message.message.update(:bounce_for_id => original_message.id, :domain_id => original_message.domain_id)
                    queued_message.message.create_delivery('Processed', :details => "This has been detected as a bounce message for <msg:#{original_message.id}>.")
                    original_message.bounce!(queued_message.message)
                    log "#{log_prefix} Bounce linked with message #{original_message.id}"
                  end
                  queued_message.destroy
                  next
                end

                # This message was sent to the return path but hasn't been matched
                # to an original message. If we have a route for this, route it
                # otherwise we'll drop at this point.
                if queued_message.message.route_id.nil?
                  log "#{log_prefix} No source messages found. Hard failing."
                  queued_message.message.create_delivery('HardFail', :details => "This message was a bounce but we couldn't link it with any outgoing message and there was no route for it.")
                  queued_message.destroy
                  next
                end
              end

              #
              # Update live stats
              #
              queued_message.message.database.live_stats.increment(queued_message.message.scope)

              #
              # Inspect incoming messages
              #
              if queued_message.message.inspected == 0
                log "#{log_prefix} Inspecting message"
                queued_message.message.inspect_message
                if queued_message.message.inspected == 1
                  is_spam = queued_message.message.spam_score > queued_message.server.spam_threshold
                  queued_message.message.update(:spam => 1) if is_spam
                  queued_message.message.append_headers(
                    "X-Venmail-Spam: #{queued_message.message.spam == 1 ? 'yes' : 'no'}",
                    "X-Venmail-Spam-Threshold: #{queued_message.server.spam_threshold}",
                    "X-Venmail-Spam-Score: #{queued_message.message.spam_score}",
                    "X-Venmail-Threat: #{queued_message.message.threat == 1 ? 'yes' : 'no'}"
                  )
                  log "#{log_prefix} Message inspected successfully. Headers added."
                end
              end

              #
              # If this message has a SPAM score higher than is permitted
              #
              if queued_message.message.spam_score >= queued_message.server.spam_failure_threshold
                log "#{log_prefix} Message has a spam score higher than the server's maxmimum. Hard failing."
                queued_message.message.create_delivery('HardFail', :details => "Message's spam score is higher than the failure threshold for this server. Threshold is currently #{queued_message.server.spam_failure_threshold}.")
                queued_message.destroy
                next
              end

              # If the server is in development mode, hold it
              if queued_message.server.mode == 'Development' && !queued_message.manual?
                log "Server is in development mode so holding."
                queued_message.message.create_delivery('Held', :details => "Server is in development mode.")
                queued_message.destroy
                log "#{log_prefix} Server is in development mode. Holding."
                next
              end

              #
              # Find out what sort of message we're supposed to be sending and dispatch this request over to
              # the sender.
              #
              if route = queued_message.message.route

                # If the route says we're holding quananteed mail and this is spam, we'll hold this
                if route.spam_mode == 'Quarantine' && queued_message.message.spam == 1 && !queued_message.manual?
                  queued_message.message.create_delivery('Held', :details => "Message placed into quarantine.")
                  queued_message.destroy
                  log "#{log_prefix} Route says to quarantine spam message. Holding."
                  next
                end

                # If the route says we're holding quananteed mail and this is spam, we'll hold this
                if route.spam_mode == 'Fail' && queued_message.message.spam == 1 && !queued_message.manual?
                  queued_message.message.create_delivery('HardFail', :details => "Message is spam and the route specifies it should be failed.")
                  queued_message.destroy
                  log "#{log_prefix} Route says to fail spam message. Hard failing."
                  next
                end

                #
                # Messages that should be blindly accepted are blindly accepted
                #
                if route.mode == 'Accept'
                  queued_message.message.create_delivery('Processed', :details => "Message has been accepted but not sent to any endpoints.")
                  queued_message.destroy
                  log "#{log_prefix} Route says to accept without endpoint. Marking as processed."
                  next
                end

                #
                # Messages that should be accepted and held should be held
                #
                if route.mode == 'Hold'
                  log "#{log_prefix} Route says to hold message."
                  if queued_message.manual?
                    log "#{log_prefix} Message was queued manually. Marking as processed."
                    queued_message.message.create_delivery('Processed', :details => "Message has been processed.")
                  else
                    log "#{log_prefix} Message was not queued manually. Holding."
                    queued_message.message.create_delivery('Held', :details => "Message has been accepted but not sent to any endpoints.")
                  end
                  queued_message.destroy
                  next
                end

                #
                # Messages that should be bounced should be bounced (or rejected if they got this far)
                #
                if route.mode == 'Bounce' || route.mode == 'Reject'
                  if id = queued_message.send_bounce
                    queued_message.message.create_delivery('HardFail', :details => "Message has been bounced because the route asks for this. See message <msg:#{id}>")
                    log "#{log_prefix} Route says to bounce. Hard failing and sent bounce (#{id})."
                  end
                  queued_message.destroy
                  next
                end

                begin
                  if @fixed_result
                    result = @fixed_result
                  elsif route.mode == "Maildir"
                    sender = cached_sender(Postal::MaildirSender)
                    result = sender.send_message(queued_message.message)
                    if result.connect_error
                      @fixed_result = result
                    end
                  else
                    case queued_message.message.endpoint
                    when SMTPEndpoint
                      sender = cached_sender(Postal::SMTPSender, queued_message.message.recipient_domain, nil, servers: [queued_message.message.endpoint.to_smtp_client_server])
                    when HTTPEndpoint
                      sender = cached_sender(Postal::HTTPSender, queued_message.message.endpoint)
                    when AddressEndpoint
                      if queued_message.message.spam_score >= Postal.config.general.address_spam_failure_threshold
                        log "#{log_prefix} Message has a spam score higher than allowed for address endpoints. Hard failing."
                        queued_message.message.create_delivery('HardFail', details: "Message's spam score is higher than the failure threshold for this server. Threshold is currently #{Postal.config.general.address_spam_failure_threshold}.")
                        queued_message.destroy
                        next
                      else
                        sender = cached_sender(Postal::SMTPSender, queued_message.message.endpoint.domain, nil, force_rcpt_to: queued_message.message.endpoint.address)
                      end
                    else
                      log "#{log_prefix} Invalid endpoint for route (#{queued_message.message.endpoint_type})"
                      queued_message.message.create_delivery('HardFail', details: "Invalid endpoint for route.")
                      queued_message.destroy
                      next
                    end
                  
                    result = sender.send_message(queued_message.message)
                    if result.connect_error
                      @fixed_result = result
                    end
                  end
                end

                # Log the result
                log_details = result.details
                if result.type =='HardFail' && result.suppress_bounce
                  # The delivery hard failed, but requested that no bounce be sent
                  log "#{log_prefix} Suppressing bounce message after hard fail"
                elsif result.type =='HardFail' && queued_message.message.send_bounces?
                  # If the message is a hard fail, send a bounce message for this message.
                  log "#{log_prefix} Sending a bounce because message hard failed"
                  if bounce_id = queued_message.send_bounce
                    log_details += ". " unless log_details =~ /\.\z/
                    log_details += " Sent bounce message to sender (see message <msg:#{bounce_id}>)"
                  end
                end

                queued_message.message.create_delivery(result.type, :details => log_details, :output => result.output&.strip, :sent_with_ssl => result.secure, :log_id => result.log_id, :time => result.time)

                if result.retry
                  log "#{log_prefix} Message requeued for trying later."
                  queued_message.retry_later(result.retry.is_a?(Integer) ? result.retry : nil)
                  queued_message.allocate_ip_address(exclude_current: true)
                  queued_message.update_column(:ip_address_id, queued_message.ip_address&.id)
                else
                  log "#{log_prefix} Message processing completed."
                  if route.mode != "Maildir"
                    queued_message.message.endpoint.mark_as_used
                  end
                  queued_message.destroy
                end
              else
                log "#{log_prefix} No route and/or endpoint available for processing. Hard failing."
                queued_message.message.create_delivery('HardFail', :details => "Message does not have a route and/or endpoint available for delivery.")
                queued_message.destroy
                next
              end
            end

            #
            # Handle Outgoing Messages
            #
            if queued_message.message.scope == 'outgoing'
              if queued_message.message.domain.nil?
                log "#{log_prefix} Message has no domain. Hard failing."
                queued_message.message.create_delivery('HardFail', :details => "Message's domain no longer exist")
                queued_message.destroy
                next
              end

              if queued_message.server.block_outgoing_without_verified_route? && !queued_message.server.has_verified_route_for?(queued_message.message.domain)
                log "#{log_prefix} Outgoing blocked because domain has no verified incoming route."
                queued_message.message.create_delivery('HardFail', :details => "Outgoing blocked: domain has no verified incoming route on this server.")
                queued_message.destroy
                next
              end

              #
              # If there's no to address, we can't do much. Fail it.
              #
              if queued_message.message.rcpt_to.blank?
                log "#{log_prefix} Message has no to address. Hard failing."
                queued_message.message.create_delivery('HardFail', :details => "Message doesn't have an RCPT to")
                queued_message.destroy
                next
              end

              #
              # If the credentials for this message is marked as holding and this isn't manual, hold it
              #
              if !queued_message.manual? && queued_message.message.credential && queued_message.message.credential.hold?
                log "#{log_prefix} Credential wants us to hold messages. Holding."
                queued_message.message.create_delivery('Held', :details => "Credential is configured to hold all messages authenticated by it.")
                queued_message.destroy
                next
              end

              #
              # If the recipient is on the suppression list and this isn't a manual queueing block sending
              #
              if !queued_message.manual? && sl = queued_message.server.message_db.suppression_list.get(:recipient, queued_message.message.rcpt_to)
                log "#{log_prefix} Recipient is on the suppression list. Holding."
                queued_message.message.create_delivery('Held', :details => "Recipient (#{queued_message.message.rcpt_to}) is on the suppression list (reason: #{sl['reason']})")
                queued_message.destroy
                next
              end

              # Extract a tag and add it to the message if one doesn't exist
              if queued_message.message.tag.nil? && tag = queued_message.message.headers['x-venmail-tag']
                log "#{log_prefix} Added tag #{tag.last}"
                queued_message.message.update(:tag => tag.last)
              end

              # Parse the content of the message as appropriate
              if queued_message.message.should_parse?
                log "#{log_prefix} Parsing message content as it hasn't been parsed before"
                queued_message.message.parse_content
              end

              # Inspect outgoing messages when there's a threshold set for the server
              if queued_message.message.inspected == 0 && queued_message.server.outbound_spam_threshold
                log "#{log_prefix} Inspecting message"
                queued_message.message.inspect_message
                if queued_message.message.inspected == 1
                  if queued_message.message.spam_score >= queued_message.server.outbound_spam_threshold
                    queued_message.message.update(:spam => 1)
                  end
                  log "#{log_prefix} Message inspected successfully"
                end
              end

              if queued_message.message.spam == 1
                queued_message.message.database.statistics.increment_all(Time.now, 'spam')
                queued_message.message.create_delivery("HardFail", :details => "Message is likely spam. Threshold is #{queued_message.server.outbound_spam_threshold} and the message scored #{queued_message.message.spam_score}.")
                queued_message.destroy
                log "#{log_prefix} Message is spam (#{queued_message.message.spam_score}). Hard failing."
                next
              end

              detector = Postal::CompromiseDetector.new
              detection = detector.analyze(queued_message.message)
              if detection.suspicious?
                pairs = detection.codes.zip(detection.descriptions)
                if pairs.any?
                  values = pairs.map { |code, desc| [queued_message.message.id, code, 10, desc] }
                  queued_message.message.database.insert_multi(:spam_checks, [:message_id, :code, :score, :description], values)
                end

                window_seconds = (Postal.config.general.compromise.hour_window rescue 3600).to_i
                base_where = { :scope => 'outgoing', :timestamp => { :greater_than => (Time.now - window_seconds).to_f } }
                if queued_message.message.credential_id
                  base_where[:credential_id] = queued_message.message.credential_id
                else
                  base_where[:domain_id] = queued_message.message.domain_id
                end
                ids = queued_message.server.message_db.select(:messages, :where => base_where, :fields => [:id])
                msg_ids = ids.map { |h| h['id'] }
                suspicious_unique = 0
                if msg_ids.any?
                  countable_codes = Postal::CompromiseDetector.countable_codes
                  sc = queued_message.server.message_db.select(:spam_checks, :where => {:message_id => msg_ids, :code => countable_codes}, :fields => [:message_id])
                  suspicious_unique = sc.map { |s| s['message_id'] }.uniq.count
                end

                suspicious_threshold = (Postal.config.general.compromise.suspicious_threshold rescue 5).to_i
                should_hold = detection.strong? || suspicious_unique >= suspicious_threshold
                
                if should_hold && (cred = queued_message.message.credential)
                  # Check for at least 3 other compromise patterns on the same day (excluding current message)
                  day_start = Time.now.beginning_of_day.to_f
                  day_end = Time.now.end_of_day.to_f
                  day_where = { 
                    :scope => 'outgoing', 
                    :credential_id => cred.id,
                    :timestamp => { :greater_than => day_start, :less_than_or_equal_to => day_end }
                  }
                  day_msg_ids = queued_message.server.message_db.select(:messages, :where => day_where, :fields => [:id]).map { |h| h['id'] }
                  day_compromise_count = 0
                  if day_msg_ids.any?
                    # Exclude current message from count
                    other_msg_ids = day_msg_ids - [queued_message.message.id]
                    if other_msg_ids.any?
                      countable_codes = Postal::CompromiseDetector.countable_codes
                      day_sc = queued_message.server.message_db.select(:spam_checks, :where => {:message_id => other_msg_ids, :code => countable_codes}, :fields => [:message_id])
                      day_compromise_count = day_sc.map { |s| s['message_id'] }.uniq.count
                    end
                  end
                  
                  # Check if this is a bulk send (same subject on same day = same mail to multiple recipients)
                  bulk_recipient_count = 0
                  if queued_message.message.subject.present?
                    bulk_where = {
                      :scope => 'outgoing',
                      :credential_id => cred.id,
                      :subject => queued_message.message.subject,
                      :timestamp => { :greater_than => day_start, :less_than_or_equal_to => day_end }
                    }
                    bulk_messages = queued_message.server.message_db.select(:messages, :where => bulk_where, :fields => [:id, :rcpt_to])
                    bulk_recipient_count = bulk_messages.map { |m| m['rcpt_to'] }.compact.uniq.count
                  end
                  
                  # Only hold if:
                  # - At least 3 other compromise patterns found for same day, OR
                  # - Bulk send with more than 20 recipients
                  min_patterns_required = (Postal.config.general.compromise.min_patterns_for_hold rescue 3).to_i
                  bulk_threshold = (Postal.config.general.compromise.bulk_hold_threshold rescue 20).to_i
                  
                  if day_compromise_count >= min_patterns_required || bulk_recipient_count > bulk_threshold
                    cred.update(:hold => true)
                    WebhookRequest.trigger(
                      queued_message.server,
                      'CredentialLocked',
                      {
                        :server => queued_message.server.webhook_hash,
                        :credential => { :id => cred.id, :uuid => cred.uuid, :name => cred.name, :type => cred.type },
                        :message => queued_message.message.webhook_hash,
                        :reason => 'Compromise suspected',
                        :detection_codes => detection.codes,
                        :detection_descriptions => detection.descriptions,
                        :count_last_hour => suspicious_unique,
                        :count_same_day => day_compromise_count,
                        :bulk_recipient_count => bulk_recipient_count
                      }
                    )
                    queued_message.message.create_delivery('Held', :details => "Message held due to suspected credential compromise")
                    queued_message.destroy
                    next
                  else
                    log "#{log_prefix} Compromise detected but not holding credential: only #{day_compromise_count} patterns today (need #{min_patterns_required}), bulk recipients: #{bulk_recipient_count} (need >#{bulk_threshold})"
                    # Still hold the message even if we don't hold the credential
                    queued_message.message.create_delivery('Held', :details => "Message held due to suspected credential compromise (insufficient patterns for credential hold)")
                    queued_message.destroy
                    next
                  end
                elsif should_hold
                  queued_message.server.suspend("Compromise suspected")
                  WebhookRequest.trigger(
                    queued_message.server,
                    'ServerSuspended',
                    {
                      :server => queued_message.server.webhook_hash,
                      :message => queued_message.message.webhook_hash,
                      :reason => 'Compromise suspected',
                      :detection_codes => detection.codes,
                      :detection_descriptions => detection.descriptions,
                      :count_last_hour => suspicious_unique
                    }
                  )
                  queued_message.message.create_delivery('Held', :details => "Message held due to suspected credential compromise")
                  queued_message.destroy
                  next
                end
              end

              # Add outgoing headers
              if !queued_message.message.has_outgoing_headers?
                queued_message.message.add_outgoing_headers
              end

              # Domain daily send limit enforcement
              if (dm = queued_message.message.domain) && dm.daily_send_limit.present? && dm.daily_send_limit.to_i > 0
                sent_last_24h = queued_message.server.message_db.select(
                  :messages,
                  :where => { :scope => 'outgoing', :timestamp => { :greater_than => 24.hours.ago.to_f }, :domain_id => dm.id },
                  :count => true
                )
                if sent_last_24h >= dm.daily_send_limit
                  prev = dm.send_limit_exceeded_at
                  now = Time.now
                  dm.update_columns(:send_limit_exceeded_at => now, :send_limit_approaching_at => nil)
                  if prev.nil? || prev < 10.minutes.ago
                    WebhookRequest.trigger(
                      queued_message.server,
                      'DomainSendLimitExceeded',
                      { :server => queued_message.server.webhook_hash, :domain => { id: dm.id, name: dm.name }, :volume_24h => sent_last_24h, :limit => dm.daily_send_limit }
                    )
                  end
                  queued_message.message.create_delivery('Held', :details => "Message held because domain daily send limit (#{dm.daily_send_limit}) has been reached.")
                  queued_message.destroy
                  log "#{log_prefix} Domain daily send limit has been exceeded. Holding."
                  next
                elsif sent_last_24h >= (dm.daily_send_limit * 0.9)
                  prev = dm.send_limit_approaching_at
                  now = Time.now
                  dm.update_columns(:send_limit_approaching_at => now, :send_limit_exceeded_at => nil)
                  if prev.nil? || prev < 10.minutes.ago
                    WebhookRequest.trigger(
                      queued_message.server,
                      'DomainSendLimitApproaching',
                      { :server => queued_message.server.webhook_hash, :domain => { id: dm.id, name: dm.name }, :volume_24h => sent_last_24h, :limit => dm.daily_send_limit }
                    )
                  end
                else
                  dm.update_columns(:send_limit_approaching_at => nil, :send_limit_exceeded_at => nil)
                end
              end

              # Check send limits
              if queued_message.server.send_limit_exceeded?
                prev = queued_message.server.send_limit_exceeded_at
                now = Time.now
                queued_message.server.update_columns(:send_limit_exceeded_at => now, :send_limit_approaching_at => nil)
                if prev.nil? || prev < 10.minutes.ago
                  WebhookRequest.trigger(
                    queued_message.server,
                    'SendLimitExceeded',
                    { :server => queued_message.server.webhook_hash, :volume => queued_message.server.send_volume, :limit => queued_message.server.send_limit }
                  )
                end
                queued_message.message.create_delivery('Held', :details => "Message held because send limit (#{queued_message.server.send_limit}) has been reached.")
                queued_message.destroy
                log "#{log_prefix} Server send limit has been exceeded. Holding."
                next
              elsif queued_message.server.send_limit_approaching?
                prev = queued_message.server.send_limit_approaching_at
                now = Time.now
                queued_message.server.update_columns(:send_limit_approaching_at => now, :send_limit_exceeded_at => nil)
                if prev.nil? || prev < 10.minutes.ago
                  WebhookRequest.trigger(
                    queued_message.server,
                    'SendLimitApproaching',
                    { :server => queued_message.server.webhook_hash, :volume => queued_message.server.send_volume, :limit => queued_message.server.send_limit }
                  )
                end
              else
                queued_message.server.update_columns(:send_limit_approaching_at => nil, :send_limit_exceeded_at => nil)
              end

              # Update the live stats for this message.
              queued_message.message.database.live_stats.increment(queued_message.message.scope)

              # If the server is in development mode, hold it
              if queued_message.server.mode == 'Development' && !queued_message.manual?
                log "Server is in development mode so holding."
                queued_message.message.create_delivery('Held', :details => "Server is in development mode.")
                queued_message.destroy
                log "#{log_prefix} Server is in development mode. Holding."
                next
              end

              # Send the outgoing message to the SMTP sender
              begin
                if @fixed_result
                  result = @fixed_result
                else
                  sender = cached_sender(Postal::SMTPSender, queued_message.message.recipient_domain, queued_message.ip_address)
                  result = sender.send_message(queued_message.message)
                  if result.connect_error
                    @fixed_result = result
                  end
                end
              end

              #
              # If the message has been hard failed, check to see how many other recent hard fails we've had for the address
              # and if there are more than 2, suppress the address for 30 days.
              #
              if result.type == 'HardFail'
                recent_hard_fails = queued_message.server.message_db.select(:messages, :where => {:rcpt_to => queued_message.message.rcpt_to, :status => 'HardFail', :timestamp => {:greater_than => 24.hours.ago.to_f}}, :count => true)
                if recent_hard_fails >= 1
                  if queued_message.server.message_db.suppression_list.add(:recipient, queued_message.message.rcpt_to, :reason => "too many hard fails")
                    log "#{log_prefix} Added #{queued_message.message.rcpt_to} to suppression list because #{recent_hard_fails} hard fails in 24 hours"
                    result.details += "." if result.details =~ /\.\z/
                    result.details += " Recipient added to suppression list (too many hard fails)."
                  end
                end
              end

              #
              # If a message is sent successfully, remove the users from the suppression list
              #
              if result.type == 'Sent'
                if queued_message.server.message_db.suppression_list.remove(:recipient, queued_message.message.rcpt_to)
                  log "#{log_prefix} Removed #{queued_message.message.rcpt_to} from suppression list because success"
                  result.details += "." if result.details =~ /\.\z/
                  result.details += " Recipient removed from suppression list."
                end
              end

              # Log the result
              queued_message.message.create_delivery(result.type, :details => result.details, :output => result.output, :sent_with_ssl => result.secure, :log_id => result.log_id, :time => result.time)
              if result.retry
                log "#{log_prefix} Message requeued for trying later."
                queued_message.retry_later(result.retry.is_a?(Integer) ? result.retry : nil)
              else
                log "#{log_prefix} Processing complete"
                queued_message.destroy
              end
            end

          rescue => e
            log "#{log_prefix} Internal error: #{e.class}: #{e.message}"
            e.backtrace.each { |e| log("#{log_prefix} #{e}") }
            queued_message.retry_later
            log "#{log_prefix} Queued message was unlocked"
            if defined?(Raven)
              Raven.capture_exception(e, :extra => {:job_id => self.id, :server_id => queued_message.server_id, :message_id => queued_message.message_id})
            end
            if queued_message.message
              queued_message.message.create_delivery("Error", :details => "An internal error occurred while sending this message. This message will be retried automatically. If this persists, contact support for assistance.", :output => "#{e.class}: #{e.message}".to_s[0, 400].strip, :log_id => "J-#{self.id}")
            end
          end
        end

      else
        log "Couldn't get lock for message #{params['id']}. I won't do this."
      end
    else
      log "No queued message with ID #{params['id']} was available for processing."
    end
  ensure
    @sender&.finish rescue nil
  end

  private

  def cached_sender(klass, *args)
    @sender ||= begin
      log "Creating sender for #{klass} with args: #{args.inspect}"
      sender = klass.new(*args)
      sender.start
      sender
    end
  end
end
