# frozen_string_literal: true

require "test_helper"
require "openssl"

# Api::Signals::FromHubController — PRD §5, §8, §13.2.
#
# HMAC-authenticated inbound endpoint for Hub fanout events. Allowlisted in
# `Auth::ApiKeyAuthenticator::PUBLIC_ALLOWLIST_PATHS` (does NOT use X-API-Key).
# Tenant is resolved from the payload's `tenant_slug`. Body is signed with
# `HUB_INGRESS_SECRET` per `Auth::HubHmacVerifier`.
module Api
  module Signals
    class FromHubControllerTest < ActionDispatch::IntegrationTest
      SECRET = "test-hub-ingress-secret-32bytes!"

      setup do
        @prev_secret = ENV["HUB_INGRESS_SECRET"]
        ENV["HUB_INGRESS_SECRET"] = SECRET
        @tenant = tenants(:acme_gmbh_de)
        ensure_signal_catalog_seeded
      end

      teardown do
        ENV["HUB_INGRESS_SECRET"] = @prev_secret
        Current.tenant = nil
      end

      def ensure_signal_catalog_seeded
        return if SignalDefinition.exists?
        YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each { |row| SignalDefinition.create!(row) }
      end

      def signed_post(payload)
        body = payload.to_json
        ts = Time.now.to_i
        sig = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{ts}.#{body}")
        post "/api/signals/from-hub",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-VPI-Signature" => "t=#{ts},v1=#{sig}"
             }
      end

      def valid_payload(slug: @tenant.slug, source_event_id: "evt-#{SecureRandom.hex(4)}")
        {
          tenant_slug: slug,
          vendor_ref: { normalized_name: "hub vendor co", tax_id: "DE-HUB-1" },
          signal_code: "invoice.late_ratio_30d",
          source_system: "invoice_recon",
          source_event_id: source_event_id,
          value_numeric: 0.22,
          recorded_at: Time.now.utc.iso8601
        }
      end

      test "valid signed POST → 202, signal ingested" do
        signed_post(valid_payload)
        assert_response :accepted
        body = JSON.parse(response.body)
        assert_equal "accepted", body["status"]
        assert body["signal_id"].present?, "expected signal_id in 202 body"
      end

      test "invalid signature → 401 INVALID_SIGNATURE" do
        body = valid_payload.to_json
        post "/api/signals/from-hub",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-VPI-Signature" => "t=#{Time.now.to_i},v1=deadbeef00"
             }
        assert_response :unauthorized
        err = JSON.parse(response.body).dig("error", "code")
        assert_equal "INVALID_SIGNATURE", err
      end

      test "missing signature header → 401" do
        body = valid_payload.to_json
        post "/api/signals/from-hub",
             params: body,
             headers: { "Content-Type" => "application/json" }
        assert_response :unauthorized
      end

      test "stale timestamp (>5 min) → 401" do
        payload = valid_payload
        body = payload.to_json
        ts = Time.now.to_i - 600
        sig = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{ts}.#{body}")
        post "/api/signals/from-hub",
             params: body,
             headers: {
               "Content-Type" => "application/json",
               "X-VPI-Signature" => "t=#{ts},v1=#{sig}"
             }
        assert_response :unauthorized
      end

      test "unknown tenant slug → 404 INVALID_TENANT" do
        signed_post(valid_payload(slug: "does-not-exist"))
        assert_response :not_found
        err = JSON.parse(response.body).dig("error", "code")
        assert_equal "INVALID_TENANT", err
      end

      test "validation failure (missing signal_code) → 400 VALIDATION_ERROR" do
        bad = valid_payload.except(:signal_code)
        signed_post(bad)
        assert_response :bad_request
        err = JSON.parse(response.body).dig("error", "code")
        assert_equal "VALIDATION_ERROR", err
      end

      test "tenant scoping — signal stored under payload tenant only" do
        signed_post(valid_payload)
        assert_response :accepted
        body = JSON.parse(response.body)
        signal = VendorSignal.find(body["signal_id"])
        assert_equal @tenant.id, signal.tenant_id
      end
    end
  end
end
