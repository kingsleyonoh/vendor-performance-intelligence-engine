# frozen_string_literal: true

module Alerts
  # HubDispatchJob — PRD §5.5, §7.
  #
  # Reads a frozen DeliveryPayload from `risk_alerts.delivery_payload` and
  # forwards it to the Notification Hub via `Ecosystem::HubClient`.
  #
  # SNAPSHOT-FREEZING INVARIANT (PRD §15 #12, architecture_rules.md):
  # this job MUST NEVER query `tenants`, `vendors`, or `vendor_scores`.
  # The payload column is the single source of truth — that is what makes
  # alert history legally defensible across tenant renames + retries.
  #
  # Dispatch outcomes (handled in `#perform`):
  #   - HubClient :sent     → status='delivered', hub_event_id stored
  #   - HubClient :failed   → status='failed' (terminal 4xx; no Sidekiq retry)
  #   - HubClient :skipped  → status='delivered' (Hub disabled — standalone-first)
  #   - TransientFailure    → status='failed', RE-RAISED so Sidekiq retries
  #   - CircuitOpen         → status='failed', NOT raised (Sidekiq retry useless;
  #                            FailedAlertRetryJob picks up after cooldown)
  class HubDispatchJob < ApplicationJob
    queue_as :default

    # Only these starting states actually call the Hub; anything else is
    # a no-op (idempotent). Acknowledged + suppressed are operator-side
    # transitions that should not be undone by a stale enqueue.
    DISPATCHABLE_STATUSES = %w[pending failed].freeze

    def perform(risk_alert_id)
      alert = RiskAlert.find(risk_alert_id)

      unless DISPATCHABLE_STATUSES.include?(alert.status)
        Rails.logger.tagged("alerts.dispatch") do
          Rails.logger.info("HubDispatchJob: alert=#{alert.id} status=#{alert.status} skipped (non-dispatchable)")
        end
        return nil
      end

      # Move pending|failed → dispatching atomically so a concurrent
      # FailedAlertRetryJob run doesn't double-dispatch.
      alert.update_columns(status: "dispatching")
      alert.reload

      # PRD §15 #12: read from frozen column ONLY.
      payload = alert.delivery_payload

      response = nil
      begin
        response = client.send_event(payload)
      rescue Ecosystem::TransientFailure => e
        record_failure!(alert, error: e.message)
        record_audit(alert, action: "dispatch_failed_transient", error: e.message)
        raise # let Sidekiq retry per its retry policy
      rescue Ecosystem::CircuitOpen => e
        record_failure!(alert, error: "circuit open: #{e.message}")
        record_audit(alert, action: "dispatch_failed_circuit_open", error: e.message)
        return nil # FailedAlertRetryJob will reattempt later
      end

      apply_response!(alert, response)
      alert
    end

    private

    def client
      Ecosystem::HubClient.instance || Ecosystem::HubClient.new
    end

    def apply_response!(alert, response)
      case response[:status]
      when :sent
        alert.update_columns(
          status: "delivered",
          hub_event_id: response[:hub_event_id],
          last_attempt_at: Time.now.utc,
          dispatch_attempts: alert.dispatch_attempts.to_i + 1,
          last_error: nil
        )
        record_audit(alert, action: "dispatched", hub_event_id: response[:hub_event_id])
      when :skipped
        # Standalone-first: Hub disabled means we treat the alert as
        # delivered locally so the operator UI stops re-prompting.
        alert.update_columns(
          status: "delivered",
          hub_event_id: nil,
          last_attempt_at: Time.now.utc,
          dispatch_attempts: alert.dispatch_attempts.to_i + 1,
          last_error: nil
        )
        Rails.logger.tagged("alerts.dispatch") do
          Rails.logger.info("HubDispatchJob: alert=#{alert.id} hub_disabled — marking delivered without delivery")
        end
        record_audit(alert, action: "dispatched_hub_disabled")
      when :failed
        record_failure!(alert, error: response[:error] || "Hub returned #{response[:response_code]}")
        record_audit(alert, action: "dispatch_failed_terminal", error: response[:error])
      else
        # Defensive: unknown shape from HubClient — surface as a failure
        # so operators investigate, don't silently lose state.
        record_failure!(alert, error: "unknown HubClient response: #{response.inspect}")
        record_audit(alert, action: "dispatch_failed_unknown")
      end
    end

    def record_failure!(alert, error:)
      alert.update_columns(
        status: "failed",
        last_attempt_at: Time.now.utc,
        dispatch_attempts: alert.dispatch_attempts.to_i + 1,
        last_error: error.to_s
      )
    end

    def record_audit(alert, action:, **extra)
      Audit::Recorder.record(
        actor: "Alerts::HubDispatchJob",
        action: "alerts##{action}",
        entity_type: "RiskAlert",
        entity_id: alert.id,
        tenant_id: alert.tenant_id,
        after_state: { status: alert.status }.merge(extra.compact)
      )
    rescue StandardError => e
      # Audit failure must not 500 the job.
      Rails.logger.error("Audit recorder failed in HubDispatchJob: #{e.class}: #{e.message}")
    end
  end
end
