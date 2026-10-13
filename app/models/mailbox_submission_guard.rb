class MailboxSubmissionGuard < ApplicationRecord
  belongs_to :server

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
        clear_warning_if_expired!(mailbox_guard, now)
        reservation_limits = limits_for_warning_state(limits, mailbox_guard, now)

        raise LimitExceeded, :recipient_limit_per_message if exceeds?(recipient_count, reservation_limits[:mailbox_recipient_limit_per_message])
        raise LimitExceeded, :domain_recipient_limit_per_minute if exceeds?(domain_guard.minute_recipients + recipient_count, reservation_limits[:domain_recipient_limit_per_minute])
        raise LimitExceeded, :mailbox_submission_limit_per_hour if exceeds?(mailbox_guard.hour_submissions + 1, reservation_limits[:mailbox_submission_limit_per_hour])
        raise LimitExceeded, :mailbox_recipient_limit_per_day if exceeds?(mailbox_guard.day_recipients + recipient_count, reservation_limits[:mailbox_recipient_limit_per_day])

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
      configured = configured_limit(server, :mailbox_hard_fail_limit_per_day)
      return configured if configured
      return nil unless protected_domain?(domain)

      Postal.config.general.shared_free_mailbox_hard_fail_limit_per_day.to_i
    end

    def bounce_policy_for(server:, domain:)
      policy = reputation_policy_for(:server => server, :domain => domain)
      return nil unless policy

      {
        :threshold_percent => policy[:hold][:threshold_percent],
        :minimum_sample_size => policy[:hold][:minimum_sample_size]
      }
    end

    def reputation_policy_for(server:, domain:)
      absolute_failure_limit = hard_fail_limit_for(:server => server, :domain => domain)
      return nil unless absolute_failure_limit
      absolute_failure_limit = [
        absolute_failure_limit,
        config_integer(:reputation_absolute_failure_limit, 5)
      ].min

      warning_threshold = config_float(:reputation_warning_threshold_percent, 2.0)
      hold_threshold = config_float(:reputation_hold_threshold_percent, 4.0)
      unless warning_threshold.positive? && hold_threshold > warning_threshold && hold_threshold < 5.0
        warning_threshold = 2.0
        hold_threshold = 4.0
      end

      shared_domain = protected_domain?(domain)
      warning_sample = config_integer(
        shared_domain ? :shared_free_mailbox_warning_min_sample_size : :reputation_warning_min_sample_size,
        shared_domain ? 10 : 25
      )
      hold_sample = config_integer(
        shared_domain ? :shared_free_mailbox_hold_min_sample_size : :reputation_hold_min_sample_size,
        shared_domain ? 25 : 50
      )
      hold_sample = [hold_sample, warning_sample].max

      {
        :warning => {
          :threshold_percent => warning_threshold,
          :minimum_sample_size => warning_sample,
          :minimum_failures => config_integer(:reputation_warning_min_failures, 1)
        },
        :hold => {
          :threshold_percent => hold_threshold,
          :minimum_sample_size => hold_sample,
          :minimum_failures => config_integer(:reputation_hold_min_failures, 2)
        },
        :absolute_failure_limit => absolute_failure_limit,
        :warning_lifetime => config_integer(:reputation_warning_lifetime_hours, 24).hours
      }
    end

    # Commit the lock transition before touching the per-server message DB.
    # A row without lock_notification_enqueued_at is a durable outbox item.
    def begin_mailbox_lock!(server:, mailbox:, reason:, mailbox_active:, now: Time.now)
      normalized_mailbox = mailbox.to_s.strip.downcase
      guard_key = "mailbox:#{normalized_mailbox}"
      ensure_guard_exists!(server.id, guard_key)

      transaction(requires_new: true) do
        guard = where(server_id: server.id, guard_key: guard_key).lock.first!
        if guard.locked_at.nil? || (guard.lock_notification_enqueued_at.present? && mailbox_active)
          guard.update!(
            locked_at: now,
            lock_reason: reason,
            lock_notification_enqueued_at: nil
          )
        elsif guard.lock_notification_enqueued_at.nil? && guard.lock_reason != reason
          guard.update!(lock_reason: reason)
        end
        guard
      end
    end

    def enqueue_mailbox_lock_notification!(guard, now: Time.now)
      guard.with_lock do
        return false if guard.lock_notification_enqueued_at.present?

        mailbox = guard.guard_key.sub(/\Amailbox:/, '')
        WebhookRequest.trigger(
          guard.server,
          'MailboxLocked',
          mailbox: mailbox,
          reason: guard.lock_reason,
          locked_at: guard.locked_at&.iso8601
        )
        guard.update!(lock_notification_enqueued_at: now)
      end
      true
    end

    def begin_mailbox_warning!(server:, mailbox:, reason:, expires_at:, now: Time.now)
      normalized_mailbox = mailbox.to_s.strip.downcase
      guard_key = "mailbox:#{normalized_mailbox}"
      ensure_guard_exists!(server.id, guard_key)

      transaction(requires_new: true) do
        guard = where(server_id: server.id, guard_key: guard_key).lock.first!
        if guard.warning_expires_at.nil? || guard.warning_expires_at <= now
          guard.update!(
            warning_at: now,
            warning_expires_at: expires_at,
            warning_reason: reason,
            warning_notification_enqueued_at: nil
          )
        elsif guard.warning_reason != reason
          guard.update!(warning_reason: reason)
        end
        guard
      end
    end

    def enqueue_mailbox_warning_notification!(guard, now: Time.now)
      guard.with_lock do
        return false if guard.warning_notification_enqueued_at.present?

        mailbox = guard.guard_key.sub(/\Amailbox:/, '')
        WebhookRequest.trigger(
          guard.server,
          'MailboxReputationWarning',
          mailbox: mailbox,
          reason: guard.warning_reason,
          warning_at: guard.warning_at&.iso8601,
          warning_expires_at: guard.warning_expires_at&.iso8601
        )
        guard.update!(warning_notification_enqueued_at: now)
      end
      true
    end

    def retry_pending_mailbox_warnings!(now: Time.now)
      where.not(warning_at: nil)
        .where(warning_notification_enqueued_at: nil)
        .where('warning_expires_at > ?', now)
        .find_each do |guard|
          begin
            enqueue_mailbox_warning_notification!(guard, now: now)
          rescue => e
            Rails.logger.error("Mailbox warning retry failed for guard #{guard.id}: #{e.class}: #{e.message}")
          end
        end
    end

    def retry_pending_mailbox_locks!
      where.not(locked_at: nil).where(lock_notification_enqueued_at: nil).find_each do |guard|
        begin
          mailbox = guard.guard_key.sub(/\Amailbox:/, '')
          guard.server.message_db.mail_user.deactivate(mailbox)
          enqueue_mailbox_lock_notification!(guard)
        rescue => e
          Rails.logger.error("Mailbox lock retry failed for guard #{guard.id}: #{e.class}: #{e.message}")
        end
      end
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

    def clear_warning_if_expired!(guard, now)
      return if guard.warning_expires_at.nil? || guard.warning_expires_at > now

      guard.update!(
        warning_at: nil,
        warning_expires_at: nil,
        warning_reason: nil,
        warning_notification_enqueued_at: nil
      )
    end

    def limits_for_warning_state(limits, guard, now)
      return limits if guard.warning_expires_at.nil? || guard.warning_expires_at <= now

      throttled = limits.dup
      throttled[:mailbox_recipient_limit_per_message] = capped_limit(
        throttled[:mailbox_recipient_limit_per_message],
        config_integer(:reputation_throttled_recipient_limit_per_message, 1)
      )
      throttled[:mailbox_submission_limit_per_hour] = capped_limit(
        throttled[:mailbox_submission_limit_per_hour],
        config_integer(:reputation_throttled_submission_limit_per_hour, 2)
      )
      throttled[:mailbox_recipient_limit_per_day] = capped_limit(
        throttled[:mailbox_recipient_limit_per_day],
        config_integer(:reputation_throttled_recipient_limit_per_day, 5)
      )
      throttled
    end

    def capped_limit(current, cap)
      current.present? ? [current, cap].min : cap
    end

    def shared_free_domains
      Array(Postal.config.general.shared_free_domains).map { |domain| domain.to_s.downcase }
    end

    def config_float(name, fallback)
      value = Postal.config.general.public_send(name).to_f
      value.positive? ? value : fallback
    rescue NoMethodError
      fallback
    end

    def config_integer(name, fallback)
      value = Postal.config.general.public_send(name).to_i
      value.positive? ? value : fallback
    rescue NoMethodError
      fallback
    end

    def effective_limits(server, domain)
      configured = {
        :domain_recipient_limit_per_minute => configured_limit(server, :mailbox_domain_recipient_limit_per_minute),
        :mailbox_recipient_limit_per_message => configured_limit(server, :mailbox_recipient_limit_per_message),
        :mailbox_submission_limit_per_hour => configured_limit(server, :mailbox_submission_limit_per_hour),
        :mailbox_recipient_limit_per_day => configured_limit(server, :mailbox_recipient_limit_per_day)
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

    def configured_limit(server, attribute)
      raw_value = server.public_send(attribute)
      return nil if raw_value.nil?

      value = raw_value.to_i
      value.positive? ? value : 1
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
