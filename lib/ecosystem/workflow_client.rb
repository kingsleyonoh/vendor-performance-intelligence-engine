# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Ecosystem
  # Faraday 2 client to the Workflow Automation Engine (PRD §6.2 + §13.2).
  #
  # Mirrors `HubClient` — same Faraday + retry + circuit-breaker pattern
  # per `.claude/knowledge/foundation/ecosystem-client-pattern.md`.
  #
  # Singleton wired in `config/initializers/ecosystem_clients.rb`. Standalone-first:
  # when `WORKFLOW_ENGINE_ENABLED != "true"`, `execute` returns
  # `{status: :skipped, ...}` immediately without making any HTTP call (PRD §2.2).
  class WorkflowClient
    DEFAULT_BASE_URL = "http://workflow-engine.example.test"
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
      @base_url   = base_url || ENV.fetch("WORKFLOW_ENGINE_URL", DEFAULT_BASE_URL)
      @api_key    = ENV.fetch("WORKFLOW_ENGINE_API_KEY", "test-key")
      @breaker    = breaker || CircuitBreaker.new
      @connection = build_connection(adapter: adapter)
    end

    # Trigger a workflow execution. Three terminal shapes:
    #   - {status: :executed, execution_id: <uuid>, response_code: 2xx}
    #   - {status: :failed, error: <msg>, response_code: 4xx}
    #   - {status: :skipped, reason: "Workflow Engine disabled"}
    # Raises:
    #   - Ecosystem::CircuitOpen     — breaker tripped, no HTTP made
    #   - Ecosystem::TransientFailure — retried but still 5xx / network
    def execute(workflow_id:, payload:)
      return skipped_response unless enabled?

      @breaker.call do
        path = "/api/workflows/#{workflow_id}/execute"

        begin
          response = @connection.post(path) do |req|
            req.body = payload
          end
        rescue Faraday::RetriableResponse => e
          status = e.response.respond_to?(:status) ? e.response.status :
                   e.response.is_a?(Hash) ? e.response[:status] : nil
          raise TransientFailure, "Workflow Engine retry exhausted (#{status || 'unknown'})"
        rescue *RETRY_EXCEPTIONS => e
          raise TransientFailure, "Workflow Engine network failure: #{e.class}: #{e.message}"
        end

        if response.status.between?(200, 299)
          { status: :executed, execution_id: extract_execution_id(response), response_code: response.status }
        elsif RETRY_STATUSES.include?(response.status)
          raise TransientFailure, "Workflow Engine returned #{response.status}"
        else
          {
            status: :failed,
            error: extract_error_message(response),
            response_code: response.status
          }
        end
      end
    end

    def enabled?
      ENV.fetch("WORKFLOW_ENGINE_ENABLED", "false").to_s.downcase == "true"
    end

    def close
      @connection&.close
    rescue StandardError
      # close is best-effort
    end

    private

    def skipped_response
      { status: :skipped, reason: "Workflow Engine disabled" }
    end

    def extract_execution_id(response)
      body = parse_body(response)
      body.is_a?(Hash) ? (body["execution_id"] || body["id"] || body[:execution_id]) : nil
    end

    def extract_error_message(response)
      body = parse_body(response)
      if body.is_a?(Hash)
        body["error"] || body["message"] || body["detail"] || "Workflow Engine returned #{response.status}"
      else
        "Workflow Engine returned #{response.status}"
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
        f.response :logger, Rails.logger.tagged("ecosystem.workflow"), bodies: false do |logger|
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
