# frozen_string_literal: true

module Alerts
  # FailedAlertRetryJob — PRD §7, §15 #6.
  #
  # Cron worker (every 30min — see config/schedule.yml). Re-enqueues
  # `HubDispatchJob` for `risk_alerts.status='failed'` rows so the §15 #6
  # invariant holds: every failed alert is retryable without manual
  # intervention.
  #
  # Cross-tenant — runs without `Current.tenant`. The HubDispatchJob it
  # enqueues reads from the alert's frozen `delivery_payload` and never
  # re-queries (PRD §15 #12), so cross-tenant operation is safe.
  #
  # Cooldown: alerts within COOLDOWN_SECONDS of their last attempt are
  # skipped — gives Sidekiq's own retry policy time to drain before this
  # backstop kicks in.
  class FailedAlertRetryJob < ApplicationJob
    queue_as :default

    COOLDOWN_SECONDS = 5 * 60
    MAX_DISPATCH_ATTEMPTS = ENV.fetch("MAX_ALERT_DISPATCH_ATTEMPTS", "10").to_i

    def perform
      cutoff = Time.now.utc - COOLDOWN_SECONDS

      scope = RiskAlert
                .where(status: "failed")
                .where("dispatch_attempts < ?", MAX_DISPATCH_ATTEMPTS)
                .where("last_attempt_at IS NULL OR last_attempt_at < ?", cutoff)

      count = 0
      scope.find_each do |alert|
        Alerts::HubDispatchJob.perform_later(alert.id)
        count += 1
      end

      Rails.logger.tagged("alerts.retry") do
        Rails.logger.info("FailedAlertRetryJob: re-enqueued #{count} failed alert(s)")
      end

      count
    end
  end
end
