# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Ecosystem
  # Faraday 2 client to the Webhook Ingestion Engine (PRD §6 + §13.2).
  #
  # Mirrors `HubClient` / `WorkflowClient` — same Faraday + retry +
  # circuit-breaker pattern per
  # `.claude/knowledge/foundation/ecosystem-client-pattern.md`.
  #
  # Singleton wired in `config/initializers/ecosystem_clients.rb`. Standalone-first:
  # when `WEBHOOK_ENGINE_ENABLED != "true"`, every public method returns
  # `{status: :skipped, ...}` immediately without HTTP (PRD §2.2).
  #
  # Public surface (PRD §6 — Webhook Engine adapter):
  #   - list_sources                              → GET /api/sources
  #   - list_dead_letters(since:, until:, page:)  → GET /api/dead-letters
  #   - fetch_stats(since:, until:)               → GET /api/stats
  class WebhookEngineClient
    DEFAULT_BASE_URL = "http://webhook-engine.example.test"
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
      attr_accessor :instance

      def build(adapter: nil, breaker: nil, base_url: nil)
        new(adapter: adapter, breaker: breaker, base_url: base_url)
      end
    end

    attr_reader :connection, :breaker

    def initialize(adapter: nil, breaker: nil, base_url: nil)
      @base_url   = base_url || ENV.fetch("WEBHOOK_ENGINE_URL", DEFAULT_BASE_URL)
      @api_key    = ENV.fetch("WEBHOOK_ENGINE_API_KEY", "test-key")
      @breaker    = breaker || CircuitBreaker.new
      @connection = build_connection(adapter: adapter)
    end

    # GET /api/sources → upstream Webhook Engine source registry.
    # Terminal shapes:
    #   - {status: :ok, sources: [...], response_code: 2xx}
    #   - {status: :failed, error:, response_code: 4xx}
    #   - {status: :skipped, reason: "Webhook Engine disabled"}
    def list_sources
      return skipped_response unless enabled?

      get_json("/api/sources") do |body|
        { sources: extract_array(body, "sources") }
      end
    end

    # GET /api/dead-letters → paginated dead-letter records over a window.
    def list_dead_letters(since: nil, until_time: nil, page: 1)
      return skipped_response unless enabled?

      params = build_window_params(since: since, until_time: until_time)
      params[:page] = page if page

      get_json("/api/dead-letters", params: params) do |body|
        {
          dead_letters: extract_array(body, "dead_letters"),
          page:  body.is_a?(Hash) ? body["page"]  : nil,
          total: body.is_a?(Hash) ? body["total"] : nil
        }
      end
    end

    # GET /api/stats → aggregate webhook health stats over a window.
    def fetch_stats(since: nil, until_time: nil)
      return skipped_response unless enabled?

      params = build_window_params(since: since, until_time: until_time)
      get_json("/api/stats", params: params) do |body|
        { stats: body.is_a?(Hash) ? body : {} }
      end
    end

    def enabled?
      ENV.fetch("WEBHOOK_ENGINE_ENABLED", "false").to_s.downcase == "true"
    end

    def close
      @connection&.close
    rescue StandardError
      # close is best-effort
    end

    private

    def skipped_response
      { status: :skipped, reason: "Webhook Engine disabled" }
    end

    # Common GET wrapper — runs through circuit breaker, applies the
    # canonical retry/error contract, and yields the parsed body to the
    # caller for shape extraction.
    def get_json(path, params: {})
      @breaker.call do
        begin
          response = @connection.get(path, params)
        rescue Faraday::RetriableResponse => e
          status = e.response.respond_to?(:status) ? e.response.status :
                   e.response.is_a?(Hash) ? e.response[:status] : nil
          raise TransientFailure, "Webhook Engine retry exhausted (#{status || 'unknown'})"
        rescue *RETRY_EXCEPTIONS => e
          raise TransientFailure, "Webhook Engine network failure: #{e.class}: #{e.message}"
        end

        if response.status.between?(200, 299)
          body = parse_body(response)
          payload = { status: :ok, response_code: response.status }
          payload.merge!(yield(body)) if block_given?
          payload
        elsif RETRY_STATUSES.include?(response.status)
          raise TransientFailure, "Webhook Engine returned #{response.status}"
        else
          { status: :failed, error: extract_error_message(response), response_code: response.status }
        end
      end
    end

    def build_window_params(since:, until_time:)
      params = {}
      params[:since] = since if since
      params[:until] = until_time if until_time
      params
    end

    def extract_array(body, key)
      return [] unless body.is_a?(Hash)
      Array(body[key] || body[key.to_sym])
    end

    def extract_error_message(response)
      body = parse_body(response)
      if body.is_a?(Hash)
        body["error"] || body["message"] || body["detail"] || "Webhook Engine returned #{response.status}"
      else
        "Webhook Engine returned #{response.status}"
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
        f.response :logger, Rails.logger.tagged("ecosystem.webhook_engine"), bodies: false do |logger|
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
