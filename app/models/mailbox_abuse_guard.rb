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
      domain = message.domain&.name || message.authenticated_mailbox.to_s.split('@', 2).last
      policy = MailboxSubmissionGuard.reputation_policy_for(server: message.server, domain: domain)
      return false unless policy

      failure_rate = outcomes[:total].positive? ? (failures.to_f / outcomes[:total]) * 100.0 : 0.0
      absolute_limit_reached = failures >= policy[:absolute_failure_limit]
      hold_boundary_reached = policy_boundary_reached?(policy[:hold], outcomes, failure_rate)
      warning_boundary_reached = policy_boundary_reached?(policy[:warning], outcomes, failure_rate)
      return false unless absolute_limit_reached || hold_boundary_reached || warning_boundary_reached

      reason = if absolute_limit_reached
        "#{failures} outbound delivery failures in 24 hours"
      else
        "#{failures} of #{outcomes[:total]} terminal outcomes failed in 24 hours (#{failure_rate.round(2)}% failure rate)"
      end

      mailbox = message.authenticated_mailbox.to_s.downcase
      if warning_boundary_reached && !absolute_limit_reached && !hold_boundary_reached
        now = Time.now
        warning_event = MailboxSubmissionGuard.begin_mailbox_warning!(
          server: message.server,
          mailbox: mailbox,
          reason: reason,
          now: now,
          expires_at: now + policy[:warning_lifetime]
        )
        MailboxSubmissionGuard.enqueue_mailbox_warning_notification!(warning_event)
        return false
      end

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

    def policy_boundary_reached?(boundary, outcomes, failure_rate)
      outcomes[:total] >= boundary[:minimum_sample_size] &&
        outcomes[:failures] >= boundary[:minimum_failures] &&
        failure_rate >= boundary[:threshold_percent]
    end

  end
end
