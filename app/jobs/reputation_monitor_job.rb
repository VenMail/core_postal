class ReputationMonitorJob < Postal::Job
  # Monitors servers' bounce/spam rates and suspends if thresholds are exceeded.
  def perform
    threshold = (Postal.config.general.reputation_block_threshold_percent || 3.0).to_f
    credential_threshold = (Postal.config.general.reputation_credential_bounce_threshold_percent || 8.0).to_f
    min_sample = (Postal.config.general.reputation_min_sample_size || 500).to_i

    Server.where(suspended_at: nil).find_each do |server|
      stats = server.message_db.statistics.get(:daily, [:outgoing, :bounces, :spam], Time.now, 1)
      totals = stats.first ? stats.first[1] : { outgoing: 0, bounces: 0, spam: 0 }
      outgoing = totals[:outgoing].to_f
      bounces = totals[:bounces].to_f
      spam = totals[:spam].to_f

      next if outgoing < min_sample

      bounce_pct = outgoing.zero? ? 0.0 : (bounces / outgoing) * 100.0
      spam_pct = outgoing.zero? ? 0.0 : (spam / outgoing) * 100.0

      if bounce_pct >= credential_threshold
        server.credentials.where(hold: false).find_each do |cred|
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
        # Server#suspend triggers ServerSuspended webhook
      end
    end
  end
end
