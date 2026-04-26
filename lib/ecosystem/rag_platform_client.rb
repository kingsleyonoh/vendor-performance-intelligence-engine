# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Ecosystem
  # Faraday 2 client to the Multi-Agent RAG Platform (PRD §6.7 + §5.7).
  #
  # READ-ONLY enrichment client — pulls vendor background entities + their
  # relationships from the RAG Platform's graph endpoint. The engine never
  # uploads documents to RAG (PRD §12 What-NOT #3 — RAG owns ingestion).
  #
  # Mirrors HubClient / WorkflowClient / WebhookEngineClient — same Faraday
  # + retry + circuit-breaker pattern per
  # `.claude/knowledge/foundation/ecosystem-client-pattern.md`.
  #
  # Singleton wired in `config/initializers/ecosystem_clients.rb`.
  # Standalone-first: when `RAG_PLATFORM_ENABLED != "true"`, every public
  # method returns `{status: :skipped, ...}` immediately without HTTP
  # (PRD §2.2 invariant).
  #
  # Public surface:
  #   - fetch_entities(name:) → GET /api/graph/entities?type=vendor&name=...
  class RagPlatformClient
    DEFAULT_BASE_URL = "http://rag-platform.example.test"
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
      @base_url   = base_url || ENV.fetch("RAG_PLATFORM_URL", DEFAULT_BASE_URL)
      @api_key    = ENV.fetch("RAG_PLATFORM_API_KEY", "test-key")
      @breaker    = breaker || CircuitBreaker.new
      @connection = build_connection(adapter: adapter)
    end

    # GET /api/graph/entities?type=vendor&name=:normalized_name
    # Terminal shapes:
    #   - {status: :ok, entities: [...], response_code: 2xx}
    #   - {status: :failed, error:, response_code: 4xx}
    #   - {status: :skipped, reason: "RAG Platform disabled"}
    def fetch_entities(name:)
      return skipped_response unless enabled?

      get_json("/api/graph/entities", params: { type: "vendor", name: name }) do |body|
        { entities: extract_array(body, "entities") }
      end
    end

    def enabled?
      ENV.fetch("RAG_PLATFORM_ENABLED", "false").to_s.downcase == "true"
    end

    def close
      @connection&.close
    rescue StandardError
      # close is best-effort
    end

    private

    def skipped_response
      { status: :skipped, reason: "RAG Platform disabled" }
    end

    def get_json(path, params: {})
      @breaker.call do
        begin
          response = @connection.get(path, params)
        rescue Faraday::RetriableResponse => e
          status = e.response.respond_to?(:status) ? e.response.status :
                   e.response.is_a?(Hash) ? e.response[:status] : nil
          raise TransientFailure, "RAG Platform retry exhausted (#{status || 'unknown'})"
        rescue *RETRY_EXCEPTIONS => e
          raise TransientFailure, "RAG Platform network failure: #{e.class}: #{e.message}"
        end

        if response.status.between?(200, 299)
          body = parse_body(response)
          payload = { status: :ok, response_code: response.status }
          payload.merge!(yield(body)) if block_given?
          payload
        elsif RETRY_STATUSES.include?(response.status)
          raise TransientFailure, "RAG Platform returned #{response.status}"
        else
          { status: :failed, error: extract_error_message(response), response_code: response.status }
        end
      end
    end

    def extract_array(body, key)
      return [] unless body.is_a?(Hash)
      Array(body[key] || body[key.to_sym])
    end

    def extract_error_message(response)
      body = parse_body(response)
      if body.is_a?(Hash)
        body["error"] || body["message"] || body["detail"] || "RAG Platform returned #{response.status}"
      else
        "RAG Platform returned #{response.status}"
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
        f.response :logger, Rails.logger.tagged("ecosystem.rag_platform"), bodies: false do |logger|
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
