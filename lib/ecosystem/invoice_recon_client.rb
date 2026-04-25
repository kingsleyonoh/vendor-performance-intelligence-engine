# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Ecosystem
  # Faraday 2 client to the Invoice Reconciliation Engine (PRD §6 + §13.2).
  #
  # Mirrors `HubClient` / `WorkflowClient` / `WebhookEngineClient` — same
  # Faraday + retry + circuit-breaker pattern per
  # `.claude/knowledge/foundation/ecosystem-client-pattern.md`.
  #
  # Singleton wired in `config/initializers/ecosystem_clients.rb`.
  # Standalone-first: when `INVOICE_RECON_ENABLED != "true"`, every
  # public method returns `{status: :skipped, ...}` immediately without
  # HTTP (PRD §2.2).
  #
  # Public surface (PRD §6 — Invoice Reconciliation adapter):
  #   - list_late_invoices(since:, vendor_ref:, page:)  → GET /api/late-invoices
  #   - list_disputes(since:)                           → GET /api/disputes
  #   - fetch_stats(vendor_ref:, since:, until_time:)   → GET /api/stats
  class InvoiceReconClient
    DEFAULT_BASE_URL = "http://invoice-recon.example.test"
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
      @base_url   = base_url || ENV.fetch("INVOICE_RECON_URL", DEFAULT_BASE_URL)
      @api_key    = ENV.fetch("INVOICE_RECON_API_KEY", "test-key")
      @breaker    = breaker || CircuitBreaker.new
      @connection = build_connection(adapter: adapter)
    end

    # GET /api/late-invoices → upstream late-invoice records over a window.
    # Terminal shapes:
    #   - {status: :ok, invoices: [...], page:, total:, response_code: 2xx}
    #   - {status: :failed, error:, response_code: 4xx}
    #   - {status: :skipped, reason: "Invoice Recon disabled"}
    def list_late_invoices(since: nil, vendor_ref: nil, page: 1)
      return skipped_response unless enabled?

      params = build_window_params(since: since, until_time: nil)
      params[:vendor_ref] = vendor_ref if vendor_ref
      params[:page] = page if page

      get_json("/api/late-invoices", params: params) do |body|
        {
          invoices: extract_array(body, "invoices"),
          page:  body.is_a?(Hash) ? body["page"]  : nil,
          total: body.is_a?(Hash) ? body["total"] : nil
        }
      end
    end

    # GET /api/disputes → invoice disputes over a window.
    def list_disputes(since: nil)
      return skipped_response unless enabled?

      params = build_window_params(since: since, until_time: nil)
      get_json("/api/disputes", params: params) do |body|
        { disputes: extract_array(body, "disputes") }
      end
    end

    # GET /api/stats → vendor-scoped aggregate financial-signal stats.
    # Required `vendor_ref` — Invoice Recon stats are always vendor-scoped.
    def fetch_stats(vendor_ref:, since: nil, until_time: nil)
      return skipped_response unless enabled?

      params = build_window_params(since: since, until_time: until_time)
      params[:vendor_ref] = vendor_ref
      get_json("/api/stats", params: params) do |body|
        { stats: body.is_a?(Hash) ? body : {} }
      end
    end

    def enabled?
      ENV.fetch("INVOICE_RECON_ENABLED", "false").to_s.downcase == "true"
    end

    def close
      @connection&.close
    rescue StandardError
      # close is best-effort
    end

    private

    def skipped_response
      { status: :skipped, reason: "Invoice Recon disabled" }
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
          raise TransientFailure, "Invoice Recon retry exhausted (#{status || 'unknown'})"
        rescue *RETRY_EXCEPTIONS => e
          raise TransientFailure, "Invoice Recon network failure: #{e.class}: #{e.message}"
        end

        if response.status.between?(200, 299)
          body = parse_body(response)
          payload = { status: :ok, response_code: response.status }
          payload.merge!(yield(body)) if block_given?
          payload
        elsif RETRY_STATUSES.include?(response.status)
          raise TransientFailure, "Invoice Recon returned #{response.status}"
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
        body["error"] || body["message"] || body["detail"] || "Invoice Recon returned #{response.status}"
      else
        "Invoice Recon returned #{response.status}"
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
        f.response :logger, Rails.logger.tagged("ecosystem.invoice_recon"), bodies: false do |logger|
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
