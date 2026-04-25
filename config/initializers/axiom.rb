# frozen_string_literal: true

# Axiom log shipping — PRD §10b, §14.
#
# Axiom does not publish a maintained Ruby SDK gem (verified at the time
# of Phase 3 wiring). The chosen integration path: a Faraday-based HTTP
# poster that posts JSON arrays to Axiom's HTTP ingest API
# (POST https://api.axiom.co/v1/datasets/:dataset/ingest, bearer token).
#
# When AXIOM_TOKEN or AXIOM_DATASET is unset, the shipper is a no-op —
# preserves the standalone-first invariant. Failures during shipping are
# rescued and logged so Axiom downtime can never crash a request.
#
# Sampling: 1-in-10 INFO logs ship; WARN/ERROR/FATAL all ship. This caps
# the egress volume for routine traffic while never losing error context.
require "faraday"

module Vpi
  module AxiomShipper
    AXIOM_INGEST_HOST = "https://api.axiom.co"
    SAMPLE_RATE = 0.10

    class << self
      def enabled?
        return @enabled if defined?(@enabled) && !@enabled.nil?

        @enabled = !ENV["AXIOM_TOKEN"].to_s.empty? && !ENV["AXIOM_DATASET"].to_s.empty?
      end

      def ship(payload)
        return nil unless enabled?

        # Only sample INFO events; ship all WARN+ events.
        level = payload.is_a?(Hash) ? (payload[:level] || payload["level"]).to_s.upcase : "INFO"
        sample = @test_rand || rand
        return nil if level == "INFO" && sample >= SAMPLE_RATE

        if @test_post
          @test_post.call(payload)
        else
          post_to_axiom(payload)
        end
        nil
      rescue StandardError => e
        # Axiom outage MUST NOT crash the request. Best effort.
        Rails.logger.error("[axiom] shipping failed: #{e.class}: #{e.message}") if defined?(Rails)
        nil
      end

      def reset!
        @enabled = nil
        @connection = nil
      end

      private

      def post_to_axiom(payload)
        token = ENV.fetch("AXIOM_TOKEN")
        dataset = ENV.fetch("AXIOM_DATASET")
        connection.post("/v1/datasets/#{dataset}/ingest") do |req|
          req.headers["Authorization"] = "Bearer #{token}"
          req.headers["Content-Type"] = "application/json"
          req.body = [payload].to_json
        end
      end

      def connection
        @connection ||= Faraday.new(url: AXIOM_INGEST_HOST) do |f|
          f.options.open_timeout = 2
          f.options.timeout = 5
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
