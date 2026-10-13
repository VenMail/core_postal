class MailboxAbuseGuard
  class << self
    def active?(message)
      return true unless protected_message?(message)

      message.database.mail_user.active?(message.authenticated_mailbox)
    end

    # Return true when delivery was stopped. Preserve the message and its audit
    # trail: an operator needs that evidence to release or investigate it.
    def hold_if_inactive!(queued_message, log:)
      return false if active?(queued_message.message)

      log.call("Mailbox #{queued_message.message.authenticated_mailbox} is locked. Holding queued message.")
      queued_message.message.create_delivery('Held', details: 'Authenticated mailbox is locked pending abuse review.')
      queued_message.destroy
      true
    end

    # Called after the terminal delivery has been stored so the current outcome
    # is included. The lock outbox is committed before the cross-database
    # mailbox update so the recurring monitor can finish a partial transition.
    def lock_after_delivery_failure!(message)
      return false unless protected_message?(message)
      outcomes = delivery_outcomes(message)
      failures = outcomes[:failures]
      limit = MailboxSubmissionGuard.hard_fail_limit_for(server: message.server, domain: message.domain&.name || message.authenticated_mailbox.to_s.split('@', 2).last)
      hard_failure_limit_reached = limit && failures >= limit

      reason = if hard_failure_limit_reached
        "#{failures} outbound delivery failures in 24 hours"
      else
        policy = MailboxSubmissionGuard.bounce_policy_for(server: message.server, domain: message.domain&.name || message.authenticated_mailbox.to_s.split('@', 2).last)
        return false unless policy

        bounce_rate = outcomes[:total].positive? ? (outcomes[:failures].to_f / outcomes[:total]) * 100.0 : 0.0
        return false unless outcomes[:total] >= policy[:minimum_sample_size] && bounce_rate > policy[:threshold_percent]

        "#{outcomes[:failures]} of #{outcomes[:total]} terminal outcomes failed in 24 hours (#{bounce_rate.round(2)}% bounce rate)"
      end

      mailbox = message.authenticated_mailbox.to_s.downcase
      lock_event = MailboxSubmissionGuard.begin_mailbox_lock!(
        server: message.server,
        mailbox: mailbox,
        reason: reason,
        mailbox_active: message.database.mail_user.active?(mailbox)
      )
      message.database.mail_user.deactivate(mailbox)
      MailboxSubmissionGuard.enqueue_mailbox_lock_notification!(lock_event)
      true
    rescue => e
      Rails.logger.error("Mailbox abuse outcome evaluation failed: #{e.class}: #{e.message}") if defined?(Rails)
      false
    end

    alias_method :lock_after_hard_fail!, :lock_after_delivery_failure!

    private

    def protected_message?(message)
      mailbox = message.authenticated_mailbox.to_s.strip
      return false if mailbox.blank?

      domain = message.domain&.name || mailbox.split('@', 2).last
      MailboxSubmissionGuard.hard_fail_limit_for(server: message.server, domain: domain).present?
    end

    def delivery_outcomes(message)
      since = 24.hours.ago.to_f
      mailbox = message.database.escape(message.authenticated_mailbox.to_s.downcase)
      database = message.database.database_name
      row = message.database.query(<<~SQL).first
        SELECT COUNT(*) AS total,
               COALESCE(SUM(terminal_outcomes.failed), 0) AS failures
        FROM (
          SELECT deliveries.message_id,
                 MAX(CASE WHEN deliveries.status IN ('HardFail', 'Bounced') THEN 1 ELSE 0 END) AS failed
          FROM `#{database}`.`deliveries` deliveries FORCE INDEX (`on_status_timestamp_message_id`)
          INNER JOIN `#{database}`.`messages` messages ON messages.id = deliveries.message_id
          WHERE deliveries.status IN ('Sent', 'HardFail', 'Bounced')
            AND deliveries.timestamp >= #{since}
            AND messages.scope = 'outgoing'
            AND messages.bounce = 0
            AND messages.authenticated_mailbox = #{mailbox}
          GROUP BY deliveries.message_id
        ) terminal_outcomes
      SQL

      {
        :total => row.to_h['total'].to_i,
        :failures => row.to_h['failures'].to_i
      }
    end

  end
end
