# frozen_string_literal: true

require "test_helper"

# Tests for /api/vendors/:vendor_id/aliases CRUD + /api/aliases/pending.
module Api
  class VendorAliasesControllerTest < ActionDispatch::IntegrationTest
    ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
    GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @acme = tenants(:acme_gmbh_de)
      @globex = tenants(:globex_inc_us)
      @acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme V")
      @globex_vendor = Vendor.create!(tenant: @globex, canonical_name: "Globex V")
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
    # Index
    # --------------------------------------------------------------

    test "GET /api/vendors/:id/aliases lists only that vendor's aliases" do
      VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "manual", source_ref: "m-1",
        confidence: 1.0, is_confirmed: true
      )
      VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "invoice_recon", source_ref: "ir-1",
        confidence: 0.85, is_confirmed: false
      )

      get "/api/vendors/#{@acme_vendor.id}/aliases", headers: acme_headers
      assert_equal 200, response.status
      refs = JSON.parse(response.body).fetch("aliases").map { |a| a["source_ref"] }
      assert_includes refs, "m-1"
      assert_includes refs, "ir-1"
    end

    test "GET /api/vendors/:id/aliases cross-tenant vendor returns 404" do
      get "/api/vendors/#{@acme_vendor.id}/aliases", headers: globex_headers
      assert_equal 404, response.status
    end

    # --------------------------------------------------------------
    # Create (manual alias)
    # --------------------------------------------------------------

    test "POST /api/vendors/:id/aliases creates a manual alias" do
      body = {
        alias: {
          source_system: "manual",
          source_ref: "operator-001",
          alias_text: "Old supplier name"
        }
      }
      post "/api/vendors/#{@acme_vendor.id}/aliases",
           params: body.to_json, headers: acme_headers
      assert_equal 201, response.status, response.body
      payload = JSON.parse(response.body).fetch("alias")
      assert_equal "manual", payload["source_system"]
      assert_equal true, payload["is_confirmed"]
      assert_in_delta 1.0, payload["confidence"].to_f, 0.001
    end

    test "POST /api/vendors/:id/aliases cross-tenant returns 404" do
      body = { alias: { source_system: "manual", source_ref: "xt-1" } }
      post "/api/vendors/#{@acme_vendor.id}/aliases",
           params: body.to_json, headers: globex_headers
      assert_equal 404, response.status
    end

    # --------------------------------------------------------------
    # Update (confirm pending alias)
    # --------------------------------------------------------------

    test "PATCH /api/vendors/:id/aliases/:id confirms a pending alias" do
      a = VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "invoice_recon", source_ref: "confirm-me",
        confidence: 0.85, is_confirmed: false
      )

      patch "/api/vendors/#{@acme_vendor.id}/aliases/#{a.id}",
            params: { alias: { is_confirmed: true } }.to_json,
            headers: acme_headers
      assert_equal 200, response.status
      a.reload
      assert_equal true, a.is_confirmed
    end

    test "PATCH /api/vendors/:id/aliases/:id cross-tenant returns 404" do
      a = VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "manual", source_ref: "xt-m-1",
        confidence: 1.0, is_confirmed: true
      )
      patch "/api/vendors/#{@acme_vendor.id}/aliases/#{a.id}",
            params: { alias: { is_confirmed: false } }.to_json,
            headers: globex_headers
      assert_equal 404, response.status
    end

    # --------------------------------------------------------------
    # Delete
    # --------------------------------------------------------------

    test "DELETE /api/vendors/:id/aliases/:id removes the alias" do
      a = VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "manual", source_ref: "del-1",
        confidence: 1.0, is_confirmed: true
      )
      delete "/api/vendors/#{@acme_vendor.id}/aliases/#{a.id}", headers: acme_headers
      assert_equal 200, response.status
      assert_nil VendorAlias.find_by(id: a.id)
    end

    # --------------------------------------------------------------
    # Pending queue (cross-vendor)
    # --------------------------------------------------------------

    test "GET /api/aliases/pending lists unconfirmed aliases for the caller's tenant" do
      VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "invoice_recon", source_ref: "pending-1",
        confidence: 0.85, is_confirmed: false
      )
      VendorAlias.create!(
        tenant: @acme, vendor: @acme_vendor,
        source_system: "invoice_recon", source_ref: "already-confirmed",
        confidence: 1.0, is_confirmed: true
      )
      # A pending alias in a DIFFERENT tenant — must not leak into acme's list.
      VendorAlias.create!(
        tenant: @globex, vendor: @globex_vendor,
        source_system: "invoice_recon", source_ref: "globex-pending",
        confidence: 0.85, is_confirmed: false
      )

      get "/api/aliases/pending", headers: acme_headers
      assert_equal 200, response.status
      refs = JSON.parse(response.body).fetch("aliases").map { |a| a["source_ref"] }
      assert_includes refs, "pending-1"
      assert_not_includes refs, "already-confirmed"
      assert_not_includes refs, "globex-pending"
    end
  end
end
