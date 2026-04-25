# frozen_string_literal: true

require "nats/client"

module Ecosystem
  # NATS JetStream singleton connection (PRD §6 + §13.2).
  #
  # Feature-flagged via `NATS_ENABLED` (PRD §2.2 standalone-first
  # invariant): when off, `instance` returns `nil` and any subscriber
  # job exits immediately without a network call.
  #
  # Connection params come from env (NEVER hardcoded):
  #   - NATS_URL          (default "nats://nats:4222")
  #   - NATS_CREDS_PATH   (optional path to a NATS .creds JWT/seed file)
  #   - NATS_STREAM_NAME  (default "CONTRACT_LIFECYCLE")
  #
  # Lifecycle:
  #   - `boot!` is called from `config/initializers/ecosystem_clients.rb`
  #     ONLY when `enabled?` returns true. Connection failure at boot is
  #     logged but never re-raised — the app must come up even when NATS
  #     is down. Subscriber jobs handle reconnection at run time.
  #   - `shutdown` is called from `at_exit` and is idempotent: safe even
  #     when nothing was ever connected.
  class NatsConnection
    DEFAULT_URL    = "nats://nats:4222"
    DEFAULT_STREAM = "CONTRACT_LIFECYCLE"

    class << self
      attr_accessor :instance, :client_factory

      def enabled?
        ENV.fetch("NATS_ENABLED", "false").to_s.downcase == "true"
      end

      def url
        ENV.fetch("NATS_URL", DEFAULT_URL)
      end

      def creds_path
        ENV["NATS_CREDS_PATH"]
      end

      def stream_name
        ENV.fetch("NATS_STREAM_NAME", DEFAULT_STREAM)
      end

      # Connect (or no-op when disabled). Returns the client instance, or
      # nil. Connection failure is swallowed + logged, never raised — the
      # app boots even when NATS is unreachable.
      def boot!
        return nil unless enabled?
        return @instance if @instance && responsive?(@instance)

        client = (client_factory || default_factory).call
        connect_opts = build_connect_opts
        client.connect(connect_opts)
        @instance = client
      rescue StandardError => e
        log_error("connect failed: #{e.class}: #{e.message}")
        @instance = nil
      end

      # Idempotent shutdown — safe to call multiple times, safe when
      # never connected.
      def shutdown
        return unless @instance

        begin
          @instance.close unless @instance.respond_to?(:closed?) && @instance.closed?
        rescue StandardError => e
          log_error("close failed: #{e.class}: #{e.message}")
        end
      ensure
        @instance = nil
      end

      private

      def default_factory
        -> { NATS::Client.new }
      end

      def build_connect_opts
        opts = { servers: [url] }
        opts[:user_credentials] = creds_path if creds_path && !creds_path.empty?
        opts
      end

      def responsive?(client)
        return true unless client.respond_to?(:closed?)
        !client.closed?
      end

      def log_error(msg)
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error("[ecosystem.nats] #{msg}")
        else
          warn("[ecosystem.nats] #{msg}")
        end
      end
    end
  end
end
