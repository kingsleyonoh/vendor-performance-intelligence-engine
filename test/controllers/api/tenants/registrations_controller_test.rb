# frozen_string_literal: true

require "test_helper"

# Tests for POST /api/tenants/register — PRD §5.1 + §8b + §11.
# Covers happy path (raw key returned ONCE + stored as SHA-256), env-gate off
# (SELF_REGISTRATION_ENABLED=false → 403), slug conflict → 409, validation
# errors → 400, rate limit → 429.
module Api
  module Tenants
    class RegistrationsControllerTest < ActionDispatch::IntegrationTest
      VALID_BODY = {
        slug: "new-op-ltd",
        legal_name: "New Op Ltd",
        full_legal_name: "New Operations Limited",
        display_name: "NewOp",
        address: { line1: "1 Main St", city: "London", country_code: "GB" },
        registration: { tax_id: "GB-1234567", company_number: "09876543" },
        contact: { email: "hello@newop.example", phone: "+44 20 7946 0000" },
        locale: "en-GB",
        timezone: "Europe/London",
        brand_primary_hex: "#111827",
        brand_accent_hex: "#FACC15"
      }.freeze

      setup do
        ENV["SELF_REGISTRATION_ENABLED"] = "true"
        # Clear rack-attack counters so rate-limit test is deterministic.
        Rack::Attack.cache.store.clear if Rack::Attack.cache.store.respond_to?(:clear)
      end

      teardown do
        ENV["SELF_REGISTRATION_ENABLED"] = "true"
        Rack::Attack.cache.store.clear if Rack::Attack.cache.store.respond_to?(:clear)
      end

      test "happy path returns 201 + tenant + raw api_key (printed ONCE)" do
        post "/api/tenants/register",
             params: VALID_BODY.to_json,
             headers: { "Content-Type" => "application/json" }

        assert_equal 201, response.status
        body = JSON.parse(response.body)

        assert body["tenant"], "response must include serialized tenant"
        assert_equal "new-op-ltd", body.dig("tenant", "slug")
        assert_equal "NewOp", body.dig("tenant", "display_name")

        # Raw key returned ONCE.
        assert body["api_key"].is_a?(String) && body["api_key"].length >= 20,
               "response must include a full raw api_key"

        # Stored hash must match SHA-256(full_key).
        created = Tenant.find_by(slug: "new-op-ltd")
        assert created
        assert_equal Digest::SHA256.hexdigest(body["api_key"]), created.api_key_hash

        # Prefix must be the first 12 chars of the returned key.
        assert_equal body["api_key"][0, 12], created.api_key_prefix

        # Sensitive fields must NOT be exposed.
        refute body.dig("tenant", "api_key_hash")
        refute body.dig("tenant", "api_key_prefix")
      end

      test "SELF_REGISTRATION_ENABLED=false returns 403 FORBIDDEN" do
        ENV["SELF_REGISTRATION_ENABLED"] = "false"

        post "/api/tenants/register",
             params: VALID_BODY.to_json,
             headers: { "Content-Type" => "application/json" }

        assert_equal 403, response.status
        assert_equal "FORBIDDEN", JSON.parse(response.body).dig("error", "code")
      end

      test "slug conflict returns 409 CONFLICT" do
        first_body = VALID_BODY.merge(slug: "conflicty-slug")
        post "/api/tenants/register",
             params: first_body.to_json,
             headers: { "Content-Type" => "application/json" }
        assert_equal 201, response.status

        post "/api/tenants/register",
             params: first_body.to_json,
             headers: { "Content-Type" => "application/json" }

        assert_equal 409, response.status
        assert_equal "CONFLICT", JSON.parse(response.body).dig("error", "code")
      end

      test "missing required field returns 400 VALIDATION_ERROR with details path" do
        bad = VALID_BODY.except(:slug)

        post "/api/tenants/register",
             params: bad.to_json,
             headers: { "Content-Type" => "application/json" }

        assert_equal 400, response.status
        body = JSON.parse(response.body)
        assert_equal "VALIDATION_ERROR", body.dig("error", "code")

        details = body.dig("error", "details")
        assert_kind_of Array, details
        assert details.any? { |d| d["path"].to_s.include?("slug") },
               "details must surface the missing field path — got #{details.inspect}"
      end

      test "raw api_key is NOT persisted anywhere in the DB" do
        post "/api/tenants/register",
             params: VALID_BODY.merge(slug: "storage-test").to_json,
             headers: { "Content-Type" => "application/json" }

        assert_equal 201, response.status
        raw = JSON.parse(response.body)["api_key"]
        tenant = Tenant.find_by(slug: "storage-test")

        # No column should equal the raw key literal.
        Tenant.attribute_names.each do |col|
          val = tenant[col]
          next unless val.is_a?(String)

          refute_equal raw, val, "raw API key leaked into column #{col}"
        end
      end
    end
  end
end
