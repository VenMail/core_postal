class MailboxSubmissionGuard < ApplicationRecord
  class LimitExceeded < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  class << self
    def reserve!(server:, domain:, mailbox:, recipients:, now: Time.now)
      normalized_domain = domain.to_s.strip.downcase
      normalized_mailbox = mailbox.to_s.strip.downcase
      recipient_count = recipients.to_i
      limits = effective_limits(server, normalized_domain)
      return unless limits
      return if normalized_mailbox.blank? || recipient_count <= 0

      raise LimitExceeded, :recipient_limit_per_message if exceeds?(recipient_count, limits[:mailbox_recipient_limit_per_message])

      transaction(requires_new: true) do
        domain_guard, mailbox_guard = locked_guards(server.id, normalized_domain, normalized_mailbox)
        reset_expired_windows!(domain_guard, now)
        reset_expired_windows!(mailbox_guard, now)

        raise LimitExceeded, :domain_recipient_limit_per_minute if exceeds?(domain_guard.minute_recipients + recipient_count, limits[:domain_recipient_limit_per_minute])
        raise LimitExceeded, :mailbox_submission_limit_per_hour if exceeds?(mailbox_guard.hour_submissions + 1, limits[:mailbox_submission_limit_per_hour])
        raise LimitExceeded, :mailbox_recipient_limit_per_day if exceeds?(mailbox_guard.day_recipients + recipient_count, limits[:mailbox_recipient_limit_per_day])

        domain_guard.update!(minute_recipients: domain_guard.minute_recipients + recipient_count)
        mailbox_guard.update!(
          minute_recipients: mailbox_guard.minute_recipients + recipient_count,
          hour_submissions: mailbox_guard.hour_submissions + 1,
          day_recipients: mailbox_guard.day_recipients + recipient_count
        )
      end
    end

    def protected_domain?(domain)
      shared_free_domains.include?(domain.to_s.downcase)
    end

    def hard_fail_limit_for(server:, domain:)
      configured = positive_limit(server, :mailbox_hard_fail_limit_per_day)
      return configured if configured
      return nil unless protected_domain?(domain)

      Postal.config.general.shared_free_mailbox_hard_fail_limit_per_day.to_i
    end

    private

    def locked_guards(server_id, domain, mailbox)
      keys = ["domain:#{domain}", "mailbox:#{mailbox}"].sort
      keys.each { |key| ensure_guard_exists!(server_id, key) }
      records = where(server_id: server_id, guard_key: keys).order(:guard_key).lock.to_a
      [records.find { |record| record.guard_key.start_with?('domain:') }, records.find { |record| record.guard_key.start_with?('mailbox:') }]
    end

    def ensure_guard_exists!(server_id, guard_key)
      create!(server_id: server_id, guard_key: guard_key)
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def reset_expired_windows!(guard, now)
      attributes = {}
      if guard.minute_started_at.nil? || guard.minute_started_at <= now - 1.minute
        attributes[:minute_started_at] = now.beginning_of_minute
        attributes[:minute_recipients] = 0
      end
      if guard.hour_started_at.nil? || guard.hour_started_at <= now - 1.hour
        attributes[:hour_started_at] = now.beginning_of_hour
        attributes[:hour_submissions] = 0
      end
      if guard.day_started_at.nil? || guard.day_started_at <= now - 1.day
        attributes[:day_started_at] = now.beginning_of_day
        attributes[:day_recipients] = 0
      end
      guard.update!(attributes) if attributes.present?
    end

    def shared_free_domains
      Array(Postal.config.general.shared_free_domains).map { |domain| domain.to_s.downcase }
    end

    def effective_limits(server, domain)
      configured = {
        :domain_recipient_limit_per_minute => positive_limit(server, :mailbox_domain_recipient_limit_per_minute),
        :mailbox_recipient_limit_per_message => positive_limit(server, :mailbox_recipient_limit_per_message),
        :mailbox_submission_limit_per_hour => positive_limit(server, :mailbox_submission_limit_per_hour),
        :mailbox_recipient_limit_per_day => positive_limit(server, :mailbox_recipient_limit_per_day)
      }
      return configured if configured.values.any?
      return nil unless protected_domain?(domain)

      {
        :domain_recipient_limit_per_minute => domain_recipient_limit_per_minute,
        :mailbox_recipient_limit_per_message => mailbox_recipient_limit_per_message,
        :mailbox_submission_limit_per_hour => mailbox_submission_limit_per_hour,
        :mailbox_recipient_limit_per_day => mailbox_recipient_limit_per_day
      }
    end

    def positive_limit(server, attribute)
      value = server.public_send(attribute).to_i
      value.positive? ? value : nil
    end

    def exceeds?(value, limit)
      limit.present? && value > limit
    end

    def domain_recipient_limit_per_minute
      Postal.config.general.shared_free_domain_recipient_limit_per_minute.to_i
    end

    def mailbox_recipient_limit_per_message
      Postal.config.general.shared_free_mailbox_recipient_limit_per_message.to_i
    end

    def mailbox_submission_limit_per_hour
      Postal.config.general.shared_free_mailbox_submission_limit_per_hour.to_i
    end

    def mailbox_recipient_limit_per_day
      Postal.config.general.shared_free_mailbox_recipient_limit_per_day.to_i
    end
  end
end
