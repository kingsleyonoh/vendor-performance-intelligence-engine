# frozen_string_literal: true

require "json"

module Ingestion
  # ContractLifecycleNatsConsumerJob — PRD §6 + §6b + §7.
  #
  # Long-running Sidekiq worker that subscribes to JetStream subject
  # `contract.obligation.>` on the configured stream
  # (`NATS_STREAM_NAME`, default "CONTRACT_LIFECYCLE") and routes each
  # message through `Ingestion::SignalIngester`.
  #
  # Standalone-first (PRD §2.2): when `NATS_ENABLED != "true"` (or no
  # `NatsConnection.instance` exists), the job exits immediately as a
  # no-op. The core engine works fully without NATS.
  #
  # Ack-vs-nack policy:
  #   - Successful ingest                   → ack
  #   - Successful dedup / rejection (terminal) → ack
  #   - Malformed payload (bad JSON)        → ack (don't redeliver garbage)
  #   - Unknown tenant_slug                 → ack (terminal)
  #   - Transient error (DB / connection)   → nack (redeliver via JetStream)
  #
  # SIGTERM handling: a `Signal.trap("TERM")` flips a stop flag. The
  # current message finishes processing + ack, then the loop exits.
  #
  # Tests inject a fake NATS connection via `NatsConnection.instance =`.
  # `perform(once: true)` drains the queue once (used in tests) instead
  # of looping forever.
  class ContractLifecycleNatsConsumerJob < ApplicationJob
    queue_as :long_running

    SUBJECT  = "contract.obligation.>"
    DURABLE  = "vpi-contract-lifecycle-consumer"
    POLL_TIMEOUT = 1 # seconds — how long next_msg blocks when idle

    # Long-running entry point. `once:` (used in tests) drains the
    # subscription once and returns. `stop_after:` (used in tests) caps
    # processed messages.
    def perform(once: false)
      return :skipped unless Ecosystem::NatsConnection.enabled?

      conn = Ecosystem::NatsConnection.instance
      return :skipped if conn.nil?

      subscribe!(conn)
      install_signal_trap!

      processed = 0
      loop do
        break if @stop_requested
        break if @stop_after && processed >= @stop_after

        msg = pull_next(@subscription)
        if msg.nil?
          break if once # drain mode
          next        # idle — keep polling
        end

        handle_message(msg)
        processed += 1
      end

      :stopped
    ensure
      begin
        @subscription&.unsubscribe
      rescue StandardError
        # best-effort
      end
    end

    private

    # ------------------------------------------------------------------
    # Subscription
    # ------------------------------------------------------------------

    def subscribe!(conn)
      js = conn.respond_to?(:jetstream) ? conn.jetstream : nil
      return if js.nil?

      @subscription = if js.respond_to?(:pull_subscribe)
                        js.pull_subscribe(SUBJECT, DURABLE,
                                          stream: Ecosystem::NatsConnection.stream_name)
                      else
                        js.subscribe(SUBJECT,
                                     durable: DURABLE,
                                     stream: Ecosystem::NatsConnection.stream_name)
                      end
    end

    def pull_next(subscription)
      return nil if subscription.nil?
      subscription.next_msg(timeout: POLL_TIMEOUT)
    rescue StandardError => e
      # `next_msg` raises on timeout/no-messages on some nats-pure
      # versions. Treat as drain → caller decides whether to loop.
      return nil if timeout_error?(e)
      Rails.logger.error("[contract_lifecycle_nats] pull error: #{e.class}: #{e.message}")
      nil
    end

    def timeout_error?(e)
      e.class.name.to_s.include?("Timeout") ||
        e.message.to_s.downcase.include?("timeout") ||
        e.message.to_s.downcase.include?("no messages")
    end

    def install_signal_trap!
      return if @signal_installed
      @signal_installed = true
      # In test mode skip — signal handlers leak across the suite.
      return if Rails.env.test?
      Signal.trap("TERM") { @stop_requested = true }
    rescue ArgumentError
      # signal handling not supported in this thread / platform
    end

    # ------------------------------------------------------------------
    # Per-message processing
    # ------------------------------------------------------------------

    def handle_message(msg)
      raw = msg.respond_to?(:data) ? msg.data : msg.to_s
      body = parse_json(raw)
      return ack_with_audit!(msg, action: "malformed_payload",
                             error: "invalid JSON") if body.nil?

      tenant = lookup_tenant(body)
      return ack_with_audit!(msg, action: "tenant_not_found",
                             tenant_slug: body["tenant_slug"]) if tenant.nil?

      payload = Ingestion::Mappers::ContractEngineMapper.map_event(
        event: body.merge("subject" => msg.respond_to?(:subject) ? msg.subject : nil)
      )
      return ack_with_audit!(msg, action: "unmappable_payload") if payload.nil?

      result = Ingestion::SignalIngester.call(payload: payload, tenant: tenant)
      ack(msg)
      audit_ingest(tenant: tenant, result: result, subject: msg.respond_to?(:subject) ? msg.subject : nil)
    rescue ActiveRecord::ConnectionNotEstablished,
           ActiveRecord::StatementInvalid,
           ActiveRecord::Deadlocked => e
      # Transient DB error → nack so JetStream redelivers.
      Rails.logger.error("[contract_lifecycle_nats] transient: #{e.class}: #{e.message}")
      nack(msg)
    rescue StandardError => e
      # Unknown error — ack to avoid redeliver garbage. Audit so an
      # operator can investigate.
      Rails.logger.error("[contract_lifecycle_nats] unexpected: #{e.class}: #{e.message}")
      ack_with_audit!(msg, action: "unhandled_exception", error: "#{e.class}: #{e.message}")
    end

    def parse_json(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def lookup_tenant(body)
      slug = body.is_a?(Hash) ? body["tenant_slug"] : nil
      return nil if slug.nil? || slug.to_s.empty?
      Tenant.find_by(slug: slug)
    end

    def ack(msg)
      msg.ack if msg.respond_to?(:ack)
    end

    def nack(msg)
      if msg.respond_to?(:nak)
        msg.nak
      elsif msg.respond_to?(:nack)
        msg.nack
      end
    end

    def ack_with_audit!(msg, action:, **context)
      ack(msg)
      Audit::Recorder.record(
        actor: "ContractLifecycleNatsConsumerJob",
        action: "ContractLifecycleNatsConsumerJob##{action}",
        entity_type: "VendorSignal",
        entity_id: nil,
        before_state: nil,
        after_state: context.merge(subject: (msg.respond_to?(:subject) ? msg.subject : nil))
      )
    rescue StandardError => e
      Rails.logger.warn("[contract_lifecycle_nats] audit failure: #{e.class}: #{e.message}")
    end

    def audit_ingest(tenant:, result:, subject:)
      Audit::Recorder.record(
        actor: "ContractLifecycleNatsConsumerJob",
        action: "ContractLifecycleNatsConsumerJob#message_processed",
        entity_type: "VendorSignal",
        entity_id: result[:signal]&.id,
        tenant_id: tenant.id,
        after_state: { status: result[:status], subject: subject }
      )
    rescue StandardError => e
      Rails.logger.warn("[contract_lifecycle_nats] audit failure: #{e.class}: #{e.message}")
    end
  end
end
