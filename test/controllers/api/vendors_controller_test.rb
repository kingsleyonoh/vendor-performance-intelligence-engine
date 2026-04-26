# frozen_string_literal: true

require "test_helper"

# Tests for /api/vendors CRUD surface — PRD §8b.
# Cross-tenant scenarios MUST return 404 (never 403/200), per
# `.agent/knowledge/foundation/tenant-scoping-pattern.md`.
module Api
  class VendorsControllerTest < ActionDispatch::IntegrationTest
    ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
    GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @acme = tenants(:acme_gmbh_de)
      @globex = tenants(:globex_inc_us)
    end

    teardown do
      Current.tenant = nil
      Rails.cache = @previous_cache if @previous_cache
    end

    def acme_headers
      { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
    end

    def globex_headers
      { "X-API-Key" => GLOBEX_RAW_KEY, "Content-Type" => "application/json" }
    end

    # --------------------------------------------------------------
    # Create
    # --------------------------------------------------------------

    test "POST /api/vendors creates a vendor under the caller's tenant" do
      body = {
        vendor: {
          canonical_name: "NewCo Supplier",
          country_code: "DE",
          category: "hardware",
          tax_id: "DE888888888",
          currency: "EUR",
          annual_spend_cents: 1_000_000
        }
      }

      post "/api/vendors", params: body.to_json, headers: acme_headers

      assert_equal 201, response.status, response.body
      payload = JSON.parse(response.body).fetch("vendor")
      assert_equal "NewCo Supplier", payload["canonical_name"]
      assert_equal @acme.id, Vendor.find(payload["id"]).tenant_id
    end

    test "POST /api/vendors validation error returns 400 VALIDATION_ERROR" do
      post "/api/vendors", params: { vendor: { canonical_name: "" } }.to_json, headers: acme_headers
      assert_equal 400, response.status
      assert_equal "VALIDATION_ERROR", JSON.parse(response.body).dig("error", "code")
    end

    test "POST /api/vendors with invalid status returns VALIDATION_ERROR" do
      body = { vendor: { canonical_name: "Bad", status: "bogus" } }
      post "/api/vendors", params: body.to_json, headers: acme_headers
      assert_equal 400, response.status
    end

    # --------------------------------------------------------------
    # Show
    # --------------------------------------------------------------

    test "GET /api/vendors/:id returns the vendor" do
      v = Vendor.create!(tenant: @acme, canonical_name: "Show Me")
      get "/api/vendors/#{v.id}", headers: acme_headers
      assert_equal 200, response.status
      assert_equal v.id, JSON.parse(response.body).dig("vendor", "id")
    end

    test "GET /api/vendors/:id cross-tenant returns 404 (never 403/200)" do
      acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Private")
      get "/api/vendors/#{acme_vendor.id}", headers: globex_headers
      assert_equal 404, response.status
    end

    test "GET /api/vendors/:id unknown UUID returns 404" do
      get "/api/vendors/#{SecureRandom.uuid}", headers: acme_headers
      assert_equal 404, response.status
    end

    # --------------------------------------------------------------
    # Index
    # --------------------------------------------------------------

    test "GET /api/vendors lists only the caller's vendors" do
      Vendor.create!(tenant: @acme, canonical_name: "Acme V1")
      Vendor.create!(tenant: @acme, canonical_name: "Acme V2")
      Vendor.create!(tenant: @globex, canonical_name: "Globex V1")

      get "/api/vendors", headers: acme_headers
      assert_equal 200, response.status
      body = JSON.parse(response.body)
      names = body.fetch("vendors").map { |h| h["canonical_name"] }
      assert_includes names, "Acme V1"
      assert_includes names, "Acme V2"
      assert_not_includes names, "Globex V1"
    end

    test "GET /api/vendors with pagination returns page 2" do
      60.times { |i| Vendor.create!(tenant: @acme, canonical_name: "Paged V#{i}") }

      get "/api/vendors?page=2&per_page=50", headers: acme_headers
      assert_equal 200, response.status
      body = JSON.parse(response.body)
      pag = body.fetch("pagination")
      assert_equal 2, pag["page"]
      assert_equal 50, pag["per_page"]
      assert body["vendors"].size >= 10, "expected remainder rows on page 2"
    end

    test "GET /api/vendors filter by status" do
      Vendor.create!(tenant: @acme, canonical_name: "Active One", status: "active")
      Vendor.create!(tenant: @acme, canonical_name: "Terminated One", status: "terminated")

      get "/api/vendors?status=terminated", headers: acme_headers
      body = JSON.parse(response.body)
      names = body["vendors"].map { |h| h["canonical_name"] }
      assert_includes names, "Terminated One"
      assert_not_includes names, "Active One"
    end

    test "GET /api/vendors filter by search substring (case-insensitive)" do
      Vendor.create!(tenant: @acme, canonical_name: "FooBar Corp")
      Vendor.create!(tenant: @acme, canonical_name: "Quux Ltd")

      get "/api/vendors?search=foobar", headers: acme_headers
      body = JSON.parse(response.body)
      names = body["vendors"].map { |h| h["canonical_name"] }
      assert_includes names, "FooBar Corp"
      assert_not_includes names, "Quux Ltd"
    end

    # --------------------------------------------------------------
    # Update
    # --------------------------------------------------------------

    test "PATCH /api/vendors/:id updates allowed fields" do
      v = Vendor.create!(tenant: @acme, canonical_name: "Pre")
      patch "/api/vendors/#{v.id}",
            params: { vendor: { canonical_name: "Post", category: "services" } }.to_json,
            headers: acme_headers
      assert_equal 200, response.status
      v.reload
      assert_equal "Post", v.canonical_name
      assert_equal "services", v.category
    end

    test "PATCH /api/vendors/:id cross-tenant returns 404" do
      acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Private")
      patch "/api/vendors/#{acme_vendor.id}",
            params: { vendor: { canonical_name: "Hijack" } }.to_json,
            headers: globex_headers
      assert_equal 404, response.status
    end

    # --------------------------------------------------------------
    # Delete (soft — status=terminated)
    # --------------------------------------------------------------

    test "DELETE /api/vendors/:id soft-deletes by setting status=terminated" do
      v = Vendor.create!(tenant: @acme, canonical_name: "To Go")
      delete "/api/vendors/#{v.id}", headers: acme_headers
      assert_equal 200, response.status
      v.reload
      assert_equal "terminated", v.status
      # Row still present.
      assert Vendor.exists?(v.id)
    end

    test "DELETE /api/vendors/:id cross-tenant returns 404" do
      acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Private")
      delete "/api/vendors/#{acme_vendor.id}", headers: globex_headers
      assert_equal 404, response.status
      acme_vendor.reload
      assert_equal "active", acme_vendor.status
    end

    # --------------------------------------------------------------
    # Serializer leak prevention
    # --------------------------------------------------------------

    test "response body excludes normalized_name (internal)" do
      v = Vendor.create!(tenant: @acme, canonical_name: "Internal Check")
      get "/api/vendors/#{v.id}", headers: acme_headers
      refute_match(/normalized_name/, response.body,
                   "normalized_name is an internal index key and must not be serialized")
    end
  end
end
