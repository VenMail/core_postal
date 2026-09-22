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

    # Called after the delivery status has been stored so the current hard fail
    # is included. mail_users.deactivate is conditional and therefore emits the
    # webhook only for the first worker that crosses the threshold.
    def lock_after_hard_fail!(message)
      return false unless protected_message?(message)
      failures = hard_fail_count(message)
      limit = MailboxSubmissionGuard.hard_fail_limit_for(server: message.server, domain: message.domain&.name || message.authenticated_mailbox.to_s.split('@', 2).last)
      return false unless limit && failures >= limit

      mailbox = message.authenticated_mailbox.to_s.downcase
      return false unless message.database.mail_user.deactivate(mailbox)

      WebhookRequest.trigger(
        message.server,
        'MailboxLocked',
        mailbox: mailbox,
        reason: "#{failures} outbound hard failures in 24 hours"
      )
      true
    end

    private

    def protected_message?(message)
      mailbox = message.authenticated_mailbox.to_s.strip
      return false if mailbox.blank?

      domain = message.domain&.name || mailbox.split('@', 2).last
      MailboxSubmissionGuard.hard_fail_limit_for(server: message.server, domain: domain).present?
    end

    def hard_fail_count(message)
      message.database.select(
        :messages,
        where: {
          scope: 'outgoing',
          authenticated_mailbox: message.authenticated_mailbox.to_s.downcase,
          status: 'HardFail',
          timestamp: { greater_than: 24.hours.ago.to_f }
        },
        count: true
      ).to_i
    end

  end
end
