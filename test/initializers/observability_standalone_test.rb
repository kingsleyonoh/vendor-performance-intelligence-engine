# frozen_string_literal: true

require "test_helper"

# Standalone-first regression: with every observability env var unset, the
# observability initializers must be no-ops and not raise during boot.
# This locks in PRD §2.2 — every integration is feature-flagged off by
# default, the core engine runs without any of these gems wired.
class ObservabilityStandaloneTest < ActiveSupport::TestCase
  test "Sentry config is no-op without SENTRY_DSN" do
    original = ENV["SENTRY_DSN"]
    ENV.delete("SENTRY_DSN")
    init_called = false
    Vpi::SentryConfig.configure!(init_proc: ->(*) { init_called = true })
    refute init_called, "Sentry must NOT initialize without SENTRY_DSN"
  ensure
    ENV["SENTRY_DSN"] = original
  end

  test "Axiom shipper is disabled without AXIOM_TOKEN" do
    original = ENV["AXIOM_TOKEN"]
    ENV.delete("AXIOM_TOKEN")
    Vpi::AxiomShipper.reset!
    refute Vpi::AxiomShipper.enabled?
  ensure
    ENV["AXIOM_TOKEN"] = original
    Vpi::AxiomShipper.reset!
  end

  test "Analytics::Event is disabled without POSTHOG_API_KEY" do
    original = ENV["POSTHOG_API_KEY"]
    ENV.delete("POSTHOG_API_KEY")
    Analytics::Event.reset!
    refute Analytics::Event.enabled?
    # And track is a no-op (returns nil, doesn't raise).
    assert_nil Analytics::Event.track(event: "anything", tenant_id: "x")
  ensure
    ENV["POSTHOG_API_KEY"] = original
    Analytics::Event.reset!
  end

  test "Prometheus registry exists even when PROMETHEUS_ENABLED=false" do
    # The registry should exist (initializer always runs), but the controller
    # 404s. This isolates "registry side-effect free" from "endpoint exposed".
    refute_nil Vpi::Metrics.registry
  end
end
