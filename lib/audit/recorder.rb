# frozen_string_literal: true

module Audit
  # Single entry point for every mutating controller + job that needs to
  # leave an audit trail. As of Phase 3 (Batch 023), the recorder INSERTs
  # into the `audit_log_entries` table (PRD §4.12) when the table is
  # available. If the table does not yet exist (initial bootstrap before
  # migrations land, test harnesses with a stripped DB) the recorder
  # falls back to a `[audit]`-tagged structured JSON line on
  # `Rails.logger` so the audit payload is still durable via the
  # standard log-shipping pipeline (Axiom via Lograge in prod).
  #
  # Caller contract is unchanged across the Phase 0 → Phase 3 transition:
  #
  #   Audit::Recorder.record(
  #     actor:,        # required — any object responding to :id, or a string
  #     action:,       # required — "controller#action" or "job_class#method"
  #     entity_type:,  # required — Model name as a string ("Vendor")
  #     entity_id:,    # required — UUID string or nil for aggregate actions
  #     before_state:, # optional — nil or hash; do not log PII here
  #     after_state:,  # optional — nil or hash; do not log PII here
  #     tenant_id:,    # optional — defaults to Current.tenant&.id
  #     metadata:      # optional — request-scoped extras (ip, user_agent, request_id)
  #   )
  #
  # See `.agent/knowledge/foundation/audit-recorder.md` for the full contract.
  class Recorder
    TAG = "audit"

    class << self
      def record(actor:, action:, entity_type:, entity_id:, before_state: nil, after_state: nil, tenant_id: nil, metadata: nil)
        raise ArgumentError, "actor is required" if actor.nil?

        return unless enabled?

        actor_type = actor.class.name.presence || "Object"
        actor_id   = actor_id_for(actor)
        resolved_tenant_id = tenant_id || Current.tenant&.id
        request_id = Current.respond_to?(:request_id) ? Current.request_id : nil
        merged_metadata = build_metadata(metadata, request_id)

        if db_available?
          insert_to_db(
            tenant_id: resolved_tenant_id,
            actor_type: actor_type, actor_id: actor_id,
            action: action,
            entity_type: entity_type, entity_id: entity_id,
            before_state: before_state, after_state: after_state,
            metadata: merged_metadata
          )
        else
          emit_log_line(
            tenant_id: resolved_tenant_id,
            actor_type: actor_type, actor_id: actor_id,
            action: action,
            entity_type: entity_type, entity_id: entity_id,
            before_state: before_state, after_state: after_state,
            metadata: merged_metadata,
            request_id: request_id
          )
        end
      end

      def enabled?
        ENV.fetch("AUDIT_ENABLED", "true") == "true"
      end

      # Allow opt-out of DB writes via env (used in benchmarks + the
      # subset of tests that assert on the legacy log line directly).
      def db_writes_disabled?
        ENV.fetch("AUDIT_DB_WRITES", "true") == "false"
      end

      private

      def db_available?
        return false if db_writes_disabled?

        defined?(::AuditLogEntry) &&
          ::AuditLogEntry.respond_to?(:table_exists?) &&
          ::AuditLogEntry.table_exists?
      rescue ::ActiveRecord::ActiveRecordError
        false
      end

      def insert_to_db(tenant_id:, actor_type:, actor_id:, action:, entity_type:, entity_id:, before_state:, after_state:, metadata:)
        ::AuditLogEntry.append!(
          tenant_id: tenant_id,
          actor_type: actor_type,
          actor_id: actor_id,
          action: action,
          entity_type: entity_type,
          entity_id: entity_id,
          before_state: before_state,
          after_state: after_state,
          metadata: metadata
        )
      end

      def emit_log_line(tenant_id:, actor_type:, actor_id:, action:, entity_type:, entity_id:, before_state:, after_state:, metadata:, request_id:)
        payload = {
          actor_type: actor_type,
          actor_id: actor_id,
          action: action,
          entity_type: entity_type,
          entity_id: entity_id,
          tenant_id: tenant_id,
          before_state: before_state,
          after_state: after_state,
          metadata: metadata,
          request_id: request_id,
          occurred_at: Time.current.iso8601
        }
        Rails.logger.tagged(TAG) { Rails.logger.info(payload.to_json) }
      end

      def build_metadata(metadata, request_id)
        base = metadata.is_a?(Hash) ? metadata.dup : {}
        base[:request_id] ||= request_id if request_id
        base
      end

      def actor_id_for(actor)
        return actor.id.to_s if actor.respond_to?(:id) && !actor.is_a?(String)

        actor.to_s
      end
    end
  end
end
