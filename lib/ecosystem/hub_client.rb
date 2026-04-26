# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Ecosystem
  # Raised when retries are exhausted on transient (5xx / network)
  # failures. Sidekiq jobs that use HubClient should let this bubble so
  # job retry semantics take over.
  class TransientFailure < StandardError; end

  # Faraday 2 client to the Notification Hub (PRD §6.1 + §13.2).
  #
  # Singleton wired in `config/initializers/ecosystem_clients.rb` so
  # HTTP connections are held across requests, re-initialized on
  # config reload, and gracefully closed on SIGTERM (per
  # architecture_rules.md "Shared infra").
  #
  # Standalone-first: when NOTIFICATION_HUB_ENABLED is not "true",
  # `send_event` returns `{status: :skipped, ...}` immediately without
  # making any network call (PRD §2.2 invariant).
  class HubClient
    DEFAULT_BASE_URL = "http://hub.example.test"
    OPEN_TIMEOUT     = 5
    READ_TIMEOUT     = 30
    USER_AGENT       = "vpi/0.1 (faraday)"
    RETRY_STATUSES   = [429, 502, 503, 504].freeze
    RETRY_EXCEPTIONS = [
      Faraday::ConnectionFailed,
      Faraday::TimeoutError,
      Errno::ETIMEDOUT,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED
    ].freeze

    class << self
      # Singleton instance — set by the initializer at boot.
      attr_accessor :instance

      # Convenience for tests / one-offs: build a fresh instance with
      # an injected adapter (typically Faraday::Adapter::Test).
      def build(adapter: nil, breaker: nil, base_url: nil)
        new(adapter: adapter, breaker: breaker, base_url: base_url)
      end
    end

    attr_reader :connection, :breaker

    def initialize(adapter: nil, breaker: nil, base_url: nil)
      @base_url   = base_url || ENV.fetch("NOTIFICATION_HUB_URL", DEFAULT_BASE_URL)
      @api_key    = ENV.fetch("NOTIFICATION_HUB_API_KEY", "test-key")
      @breaker    = breaker || CircuitBreaker.new
      @connection = build_connection(adapter: adapter)
    end

    # Send a Hub event payload. Three terminal shapes:
    #   - {status: :sent, hub_event_id: <uuid>, response_code: 2xx}
    #   - {status: :failed, error: <msg>, response_code: 4xx}
    #   - {status: :skipped, reason: "Hub disabled"}
    # Raises:
    #   - Ecosystem::CircuitOpen     — breaker tripped, no HTTP made
    #   - Ecosystem::TransientFailure — retried but still 5xx / network
    def send_event(payload)
      return skipped_response unless enabled?

      @breaker.call do
        begin
          response = @connection.post("/api/events") do |req|
            req.body = payload
          end
        rescue Faraday::RetriableResponse => e
          # Retry middleware exhausted on a retry-eligible status —
          # surface as transient so the caller (Sidekiq job)
          # re-enqueues per its own retry policy.
          status = e.response.respond_to?(:status) ? e.response.status :
                   e.response.is_a?(Hash) ? e.response[:status] : nil
          raise TransientFailure, "Hub retry exhausted (#{status || 'unknown'})"
        rescue *RETRY_EXCEPTIONS => e
          raise TransientFailure, "Hub network failure: #{e.class}: #{e.message}"
        end

        if response.status.between?(200, 299)
          { status: :sent, hub_event_id: extract_event_id(response), response_code: response.status }
        elsif RETRY_STATUSES.include?(response.status)
          # Reached here only if retry middleware didn't raise (e.g. an
          # adapter that doesn't honor RetriableResponse). Surface as
          # transient.
          raise TransientFailure, "Hub returned #{response.status}"
        else
          # Terminal 4xx — never retry; let the caller log + audit.
          {
            status: :failed,
            error: extract_error_message(response),
            response_code: response.status
          }
        end
      end
    end

    def enabled?
      ENV.fetch("NOTIFICATION_HUB_ENABLED", "false").to_s.downcase == "true"
    end

    # Graceful shutdown hook — close idle connections so SIGTERM-based
    # deploys don't leak sockets.
    def close
      @connection&.close
    rescue StandardError
      # close is best-effort
    end

    private

    def skipped_response
      { status: :skipped, reason: "Hub disabled" }
    end

    def extract_event_id(response)
      body = parse_body(response)
      body.is_a?(Hash) ? (body["event_id"] || body["hub_event_id"] || body[:event_id]) : nil
    end

    def extract_error_message(response)
      body = parse_body(response)
      if body.is_a?(Hash)
        body["error"] || body["message"] || body["detail"] || "Hub returned #{response.status}"
      else
        "Hub returned #{response.status}"
      end
    end

    def parse_body(response)
      return response.body if response.body.is_a?(Hash) || response.body.is_a?(Array)
      return {} if response.body.nil? || response.body.to_s.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    def build_connection(adapter:)
      Faraday.new(url: @base_url) do |f|
        f.request :json
        f.response :logger, Rails.logger.tagged("ecosystem.hub"), bodies: false do |logger|
          logger.filter(/(api[_-]?key)["':\s=]+([^"'\s,}]+)/i, '\1: [FILTERED]')
        end if defined?(Rails) && Rails.logger.respond_to?(:tagged)
        f.request :retry, retry_options
        f.headers["X-API-Key"]    = @api_key
        f.headers["Content-Type"] = "application/json"
        f.headers["Accept"]       = "application/json"
        f.headers["User-Agent"]   = USER_AGENT
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout      = READ_TIMEOUT
        f.adapter(*Array(adapter || Faraday.default_adapter))
      end
    end

    def retry_options
      {
        max:                 3,
        interval:            0.05,
        interval_randomness: 0.5,
        backoff_factor:      2,
        max_interval:        30,
        retry_statuses:      RETRY_STATUSES,
        exceptions:          RETRY_EXCEPTIONS,
        methods:             %i[post put patch get delete]
      }
    end
  end
end
