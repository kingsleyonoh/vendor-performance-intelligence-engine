# frozen_string_literal: true

# Prometheus metrics — PRD §10b, §14.
#
# Establishes a process-wide registry (default `Prometheus::Client.registry`)
# and registers a small core of VPI-specific metrics. The `/metrics`
# endpoint scrapes this registry; instrumenting code paths just calls
# `Vpi::Metrics.<name>.increment(...)` etc.
#
# When PROMETHEUS_ENABLED=false the registry is still populated, but the
# controller returns 404 — keeps a clean off-switch without unloading code.
require "prometheus/client"

module Vpi
  module Metrics
    class << self
      def registry
        @registry ||= ::Prometheus::Client.registry
      end

      def vendor_signals_inserted
        @vendor_signals_inserted ||= registry.counter(
          :vpi_vendor_signals_inserted_total,
          docstring: "Total number of vendor_signals rows inserted"
        )
      rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
        registry.get(:vpi_vendor_signals_inserted_total)
      end

      def vendor_scores_computed
        @vendor_scores_computed ||= registry.counter(
          :vpi_vendor_scores_computed_total,
          docstring: "Total number of vendor_scores rows computed"
        )
      rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
        registry.get(:vpi_vendor_scores_computed_total)
      end

      def sidekiq_queue_depth
        @sidekiq_queue_depth ||= registry.gauge(
          :vpi_sidekiq_queue_depth,
          docstring: "Sidekiq queue depth at scrape time",
          labels: [:queue]
        )
      rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
        registry.get(:vpi_sidekiq_queue_depth)
      end

      def process_rss_bytes
        @process_rss_bytes ||= registry.gauge(
          :vpi_process_rss_bytes,
          docstring: "Resident memory size of the Ruby process at scrape time"
        )
      rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
        registry.get(:vpi_process_rss_bytes)
      end

      # Refresh metrics that are sampled at scrape time rather than
      # incrementally maintained. Called from MetricsController#index.
      def refresh_sampled!
        sample_process_rss!
        sample_sidekiq_queues!
      end

      private

      def sample_process_rss!
        rss_kb = `ps -o rss= -p #{Process.pid}`.to_i rescue 0
        process_rss_bytes.set(rss_kb * 1024)
      rescue StandardError
        # Best effort — never crash the scrape.
      end

      def sample_sidekiq_queues!
        return unless defined?(::Sidekiq)

        ::Sidekiq::Queue.all.each do |q|
          sidekiq_queue_depth.set(q.size, labels: { queue: q.name })
        end
      rescue StandardError
        # Best effort — never crash the scrape.
      end
    end
  end
end

# Eagerly create the metric instances so they show up in /metrics output even
# if no instrumented path has fired yet. Wrapped — calling registry methods
# during Rails initialization is safe.
Vpi::Metrics.vendor_signals_inserted
Vpi::Metrics.vendor_scores_computed
Vpi::Metrics.sidekiq_queue_depth
Vpi::Metrics.process_rss_bytes
