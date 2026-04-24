# frozen_string_literal: true

module Audit
  # Single entry point for every mutating controller + job that needs to
  # leave an audit trail. The `audit_log` table lands in Phase 3 (PRD §4.12);
  # until then, `record` emits a `[audit]`-tagged structured JSON line on
  # `Rails.logger` so the audit payload is still durable via the standard
  # log-shipping pipeline (Axiom via Lograge in prod).
  #
  # Post-Phase 3, the body of `record` swaps the `Rails.logger.tagged` call
  # for an `INSERT INTO audit_log`. Callers do not change.
  #
  # Contract (stable across the Phase 3 transition):
  #
  #   Audit::Recorder.record(
  #     actor:,        # required — any object responding to :id, or a string
  #     action:,       # required — "controller#action" or "job_class#method"
  #     entity_type:,  # required — Model name as a string ("Vendor")
  #     entity_id:,    # required — UUID string or nil for aggregate actions
  #     before_state:, # optional — nil or hash; do not log PII here
  #     after_state:,  # optional — nil or hash; do not log PII here
  #     tenant_id:     # optional — defaults to Current.tenant&.id
  #   )
  #
  # See `.agent/knowledge/foundation/audit-recorder.md` for the full contract.
  class Recorder
    TAG = "audit"

    class << self
      def record(actor:, action:, entity_type:, entity_id:, before_state: nil, after_state: nil, tenant_id: nil)
        raise ArgumentError, "actor is required" if actor.nil?

        return unless enabled?

        payload = {
          actor_type: actor.class.name,
          actor_id: actor_id_for(actor),
          action: action,
          entity_type: entity_type,
          entity_id: entity_id,
          tenant_id: tenant_id || Current.tenant&.id,
          before_state: before_state,
          after_state: after_state,
          request_id: Current.respond_to?(:request_id) ? Current.request_id : nil,
          occurred_at: Time.current.iso8601
        }

        Rails.logger.tagged(TAG) do
          Rails.logger.info(payload.to_json)
        end
      end

      def enabled?
        ENV.fetch("AUDIT_ENABLED", "true") == "true"
      end

      private

      def actor_id_for(actor)
        return actor.id.to_s if actor.respond_to?(:id) && !actor.is_a?(String)

        actor.to_s
      end
    end
  end
end
