# frozen_string_literal: true

require "openssl"
require "active_support/security_utils"

module Auth
  # Raised by `verify!` when the HMAC signature is missing, malformed,
  # tampered, or outside the replay window.
  class InvalidHmac < StandardError; end

  # Auth::HubHmacVerifier — PRD §13.2.
  #
  # Verifies HMAC-SHA256 signatures on inbound `/api/signals/from-hub`
  # requests using the shared `HUB_INGRESS_SECRET` env var. Replay
  # protection: a 5-minute timestamp window. Comparison is constant-time
  # via `ActiveSupport::SecurityUtils.secure_compare`.
  #
  # Header format (PRD §13.2 — Stripe-style versioned signature):
  #   X-VPI-Signature: t=<unix_timestamp>,v1=<hex_hmac>
  #
  # Where `hex_hmac = HMAC_SHA256(HUB_INGRESS_SECRET, "<t>.<raw_body>")`.
  #
  # Public API:
  #   - Auth::HubHmacVerifier.verify(request)  → bool
  #   - Auth::HubHmacVerifier.verify!(request) → true; raises InvalidHmac
  #
  # `request` must respond to:
  #   - `headers["X-VPI-Signature"]` (Rails request, FakeRequest, etc.)
  #   - `raw_post` (raw body string — Rails ActionDispatch::Request supports
  #     this; call `request.body.read` once and reuse)
  class HubHmacVerifier
    HEADER_NAME      = "X-VPI-Signature"
    REPLAY_WINDOW_S  = 300 # 5 minutes
    SIGNATURE_REGEX  = /\At=(?<ts>\d+),\s*v1=(?<sig>[0-9a-fA-F]+)\z/.freeze

    class << self
      # Returns true on valid signature; false on any failure mode
      # except a missing secret (which fails fast with KeyError so
      # mis-deploys are caught at boot, not silently accepted).
      def verify(request)
        secret = ENV.fetch("HUB_INGRESS_SECRET")
        new(secret: secret).verify(request)
      end

      # Like verify, but raises Auth::InvalidHmac on failure.
      def verify!(request)
        secret = ENV.fetch("HUB_INGRESS_SECRET")
        new(secret: secret).verify!(request)
      end
    end

    def initialize(secret:, clock: -> { Time.now })
      @secret = secret
      @clock = clock
    end

    def verify(request)
      verify!(request)
    rescue InvalidHmac
      false
    end

    def verify!(request)
      header = read_header(request)
      raise InvalidHmac, "missing #{HEADER_NAME}" if header.nil? || header.empty?

      match = SIGNATURE_REGEX.match(header)
      raise InvalidHmac, "malformed #{HEADER_NAME}" unless match

      timestamp = match[:ts].to_i
      provided_sig = match[:sig].downcase

      raise InvalidHmac, "stale timestamp" unless within_replay_window?(timestamp)

      body = request.raw_post.to_s
      expected = compute_signature(timestamp: timestamp, body: body)

      unless ::ActiveSupport::SecurityUtils.secure_compare(expected, provided_sig)
        raise InvalidHmac, "signature mismatch"
      end

      true
    end

    private

    def read_header(request)
      h = request.headers
      h[HEADER_NAME] || h[HEADER_NAME.upcase] || h["HTTP_X_VPI_SIGNATURE"]
    end

    def within_replay_window?(timestamp)
      now = @clock.call.to_i
      (now - timestamp).abs <= REPLAY_WINDOW_S
    end

    def compute_signature(timestamp:, body:)
      payload = "#{timestamp}.#{body}"
      OpenSSL::HMAC.hexdigest("SHA256", @secret, payload).downcase
    end
  end
end
