# frozen_string_literal: true

module Alerts
  # WorkflowEscalationJob — PRD §6.2, §7, §13.2.
  #
  # Sister to HubDispatchJob. Fires for HIGH/CRITICAL band alerts (PRD §6.b
  # — operator escalation triggers a multi-step workflow in the Workflow
  # Automation Engine: assign owner, request mitigation plan, schedule
  # follow-up review).
  #
  # SNAPSHOT-FREEZING INVARIANT (PRD §15 #12, architecture_rules.md):
  # this job MUST NEVER query `tenants`, `vendors`, or `vendor_scores`.
  # It reads ONLY from `risk_alerts.delivery_payload` — same as
  # HubDispatchJob. That is what makes escalation history legally
  # defensible across tenant renames + retries.
  #
  # Outcomes:
  #   - WorkflowClient :executed → store workflow_execution_id, emit audit
  #   - WorkflowClient :failed   → audit only (terminal 4xx; no Sidekiq retry)
  #   - WorkflowClient :skipped  → audit only (Workflow Engine disabled — standalone-first)
  #   - TransientFailure         → re-raised so Sidekiq retries (5xx exhausted)
  #   - CircuitOpen              → swallowed (Sidekiq retry useless until cooldown)
  #
  # Idempotency: an alert with `workflow_execution_id` already populated
  # is a no-op. Band guard: only HIGH or CRITICAL alerts trigger.
  class WorkflowEscalationJob < ApplicationJob
    queue_as :default

    ESCALATION_BANDS = %w[high critical].freeze

    def perform(risk_alert_id)
      alert = RiskAlert.find(risk_alert_id)

      unless ESCALATION_BANDS.include?(alert.new_band)
        log_skip(alert, reason: "non-escalation band: #{alert.new_band}")
        return nil
      end

      if alert.workflow_execution_id.present?
        log_skip(alert, reason: "workflow_execution_id already set: #{alert.workflow_execution_id}")
        return nil
      end

      payload = build_workflow_payload(alert)

      response =
        begin
          client.execute(workflow_id: workflow_id_for_escalation, payload: payload)
        rescue Ecosystem::TransientFailure => e
          record_audit(alert, action: "escalation_failed_transient", error: e.message)
          raise # let Sidekiq retry
        rescue Ecosystem::CircuitOpen => e
          record_audit(alert, action: "escalation_failed_circuit_open", error: e.message)
          return nil # Sidekiq retry cannot help here
        end

      apply_response!(alert, response)
      alert
    end

    private

    def client
      Ecosystem::WorkflowClient.instance || Ecosystem::WorkflowClient.new
    end

    def workflow_id_for_escalation
      ENV.fetch("WORKFLOW_ENGINE_ESCALATION_WORKFLOW_ID", "vpi-risk-escalation-default")
    end

    # Build the payload sent to the Workflow Engine. Reads ONLY from the
    # alert's frozen `delivery_payload` (PRD §15 #12) — never from
    # tenants/vendors/vendor_scores.
    def build_workflow_payload(alert)
      dp = alert.delivery_payload || {}
      {
        alert_id: alert.id,
        tenant: fetch(dp, :tenant),
        vendor: fetch(dp, :vendor),
        score:  fetch(dp, :score),
        band_change: fetch(dp, :band_change) || {
          previous: alert.previous_band,
          new: alert.new_band,
          direction: alert.direction
        }
      }
    end

    # jsonb storage stringifies keys on read; tolerate either shape.
    def fetch(hash, key)
      return nil unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s]
    end

    def apply_response!(alert, response)
      case response[:status]
      when :executed
        alert.update_columns(workflow_execution_id: response[:execution_id])
        record_audit(alert,
                     action: "escalated",
                     workflow_execution_id: response[:execution_id])
      when :skipped
        Rails.logger.tagged("alerts.escalation") do
          Rails.logger.info("WorkflowEscalationJob: alert=#{alert.id} workflow_engine_disabled — no-op")
        end
        record_audit(alert, action: "escalation_skipped_workflow_disabled")
      when :failed
        record_audit(alert,
                     action: "escalation_failed_terminal",
                     error: response[:error],
                     response_code: response[:response_code])
      else
        record_audit(alert,
                     action: "escalation_failed_unknown",
                     response: response.inspect)
      end
    end

    def log_skip(alert, reason:)
      Rails.logger.tagged("alerts.escalation") do
        Rails.logger.info("WorkflowEscalationJob: alert=#{alert.id} skipped (#{reason})")
      end
    end

    def record_audit(alert, action:, **extra)
      Audit::Recorder.record(
        actor: "Alerts::WorkflowEscalationJob",
        action: "alerts##{action}",
        entity_type: "RiskAlert",
        entity_id: alert.id,
        tenant_id: alert.tenant_id,
        after_state: extra.compact
      )
    rescue StandardError => e
      Rails.logger.error("Audit recorder failed in WorkflowEscalationJob: #{e.class}: #{e.message}")
    end
  end
end
