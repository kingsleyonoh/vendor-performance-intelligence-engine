# frozen_string_literal: true

# Analytics::Event — thin facade over posthog-ruby (PRD §10b, §14).
#
# Five callsites instrument the events documented in the PRD:
#   1. vendor_viewed         → VendorsController#show
#   2. alert_acknowledged    → AlertsController#acknowledge
#   3. scoring_rule_activated → Api::ScoringRulesController#activate
#   4. report_generated      → Reports::ReportGeneratorJob (on success)
#   5. api_key_rotated       → Api::Tenants::RotateKeyController#create
#
# When POSTHOG_API_KEY or POSTHOG_HOST is unset, every callsite no-ops.
# Failures from the underlying client are swallowed — analytics MUST NEVER
# crash a request.
#
# Distinct ID convention: `tenant_id` (the unit of analysis is the tenant).
# When user-context is available, it ships in `properties[:user_id]`.
require "posthog"

module Analytics
  class Event
    class << self
      def enabled?
        return @enabled if defined?(@enabled) && !@enabled.nil?

        @enabled = !ENV["POSTHOG_API_KEY"].to_s.empty? && !ENV["POSTHOG_HOST"].to_s.empty?
      end

      def track(event:, tenant_id: nil, user_id: nil, properties: {})
        # Test-mode capture short-circuits the underlying client. Used by
        # callsite-instrumentation tests to assert "this controller fires
        # this event with these args" without standing up a real PostHog.
        if @test_capture_on
          @test_captured << {
            event: event.to_s,
            tenant_id: tenant_id,
            user_id: user_id,
            properties: { tenant_id: tenant_id, user_id: user_id }.compact.merge(properties || {})
          }
          return nil
        end

        return nil unless enabled?

        distinct_id = tenant_id.to_s.presence || "anonymous"
        merged_props = { tenant_id: tenant_id, user_id: user_id }.compact.merge(properties || {})

        client.capture(
          distinct_id: distinct_id,
          event: event.to_s,
          properties: merged_props
        )
        nil
      rescue StandardError => e
        Rails.logger.warn("[analytics] capture failed: #{e.class}: #{e.message}") if defined?(Rails)
        nil
      end

      def test_capture!
        @test_capture_on = true
        @test_captured = []
      end

      def test_capture_off!
        @test_capture_on = false
        @test_captured = []
      end

      def captured
        @test_captured || []
      end

      def reset!
        @enabled = nil
        @client = nil
      end

      def client
        return @test_client if @test_client

        @client ||= ::PostHog::Client.new(
          api_key: ENV.fetch("POSTHOG_API_KEY"),
          host: ENV.fetch("POSTHOG_HOST"),
          on_error: ->(_status, msg) { Rails.logger.warn("[analytics] posthog error: #{msg}") if defined?(Rails) }
        )
      end
    end
  end
end
