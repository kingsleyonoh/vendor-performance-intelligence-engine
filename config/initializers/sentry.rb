# frozen_string_literal: true

# Sentry error tracking — PRD §10b, §14.
#
# Configuration is wrapped in a module so tests can call it deterministically
# without booting Rails. The actual `Sentry.init` call only fires when
# SENTRY_DSN is set — keeps the standalone-first invariant: a fresh
# `git clone && docker compose up` works without Sentry credentials.
#
# Filters sensitive params + headers via `before_send`. Tags every event
# with `tenant_id` from `Current.tenant&.id` so events are tenant-attributable.
module Vpi
  module SentryConfig
    SENSITIVE_KEYS = %w[
      api_key
      apikey
      password
      passwd
      secret
      token
      authorization
      x-api-key
      x_api_key
    ].freeze

    class << self
      # init_proc is an injection point for tests. Production passes nil and
      # we use Sentry.init; tests pass a lambda that captures the block.
      def configure!(init_proc: nil)
        dsn = ENV["SENTRY_DSN"].to_s
        return if dsn.empty?

        target = init_proc || ->(&blk) { Sentry.init(&blk) }
        target.call do |config|
          config.dsn = dsn
          config.environment = Rails.env
          config.release = ENV.fetch("VPI_VERSION", "dev")
          config.breadcrumbs_logger = [:active_support_logger, :http_logger]
          config.send_default_pii = false
          config.before_send = method(:before_send)
        end
      end

      # Scrub sensitive keys from request data + headers; tag event with
      # tenant_id from Current.tenant. Hint is unused but kept for the
      # documented sentry-ruby callable signature.
      def before_send(event, _hint)
        scrubbed = deep_scrub(event)
        if Current.respond_to?(:tenant) && Current.tenant
          scrubbed["tags"] ||= {}
          scrubbed["tags"]["tenant_id"] = Current.tenant.id.to_s
        end
        scrubbed
      end

      private

      def deep_scrub(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), acc|
            acc[k] = sensitive?(k) ? "[FILTERED]" : deep_scrub(v)
          end
        when Array
          value.map { |v| deep_scrub(v) }
        else
          value
        end
      end

      def sensitive?(key)
        SENSITIVE_KEYS.any? { |s| key.to_s.downcase.include?(s) }
      end
    end
  end
end

Vpi::SentryConfig.configure!
