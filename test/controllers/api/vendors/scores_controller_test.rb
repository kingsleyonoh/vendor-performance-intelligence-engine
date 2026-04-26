# frozen_string_literal: true

require "test_helper"

# Tests for /api/vendors/:id/score/current + /score/history — PRD §8b.
module Api
  module Vendors
    class ScoresControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
      GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

      setup do
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        @acme = tenants(:acme_gmbh_de)
        @globex = tenants(:globex_inc_us)
        ensure_signal_catalog_seeded
        @rule = ensure_rule(@acme)
        ensure_rule(@globex)
        @vendor = Vendor.create!(
          tenant: @acme,
          canonical_name: "Scored Vendor Inc",
          status: "active"
        )
      end

      teardown do
        Current.tenant = nil
        Rails.cache = @previous_cache if @previous_cache
      end

      def ensure_signal_catalog_seeded
        return if SignalDefinition.exists?

        yml = YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml"))
        yml.each { |row| SignalDefinition.create!(row) }
      end

      def ensure_rule(tenant)
        ScoringRule.find_or_create_by!(tenant_id: tenant.id, name: "Default v1") do |r|
          r.is_active = true
          r.category_weights = {
            "financial" => 0.35, "operational" => 0.10, "contractual" => 0.30,
            "integration" => 0.10, "transactional" => 0.15
          }
          r.band_thresholds = { "low_max" => 30, "medium_max" => 60, "high_max" => 85 }
          r.window_days = 90
          r.time_decay_half_life_days = 45
        end
      end

      def acme_headers
        { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
      end

      def globex_headers
        { "X-API-Key" => GLOBEX_RAW_KEY, "Content-Type" => "application/json" }
      end

      def build_score(band: "low", score: 20.0, computed_at: Time.now.utc, vendor: @vendor)
        VendorScore.create!(
          tenant: vendor.tenant,
          vendor: vendor,
          scoring_rule: ScoringRule.where(tenant_id: vendor.tenant_id, is_active: true).first,
          composite_score: score,
          band: band,
          trend: "new",
          category_scores: {
            "financial" => score, "operational" => score, "contractual" => score,
            "integration" => score, "transactional" => score
          },
          top_contributors: [],
          window_days: 90,
          signals_considered_count: 3,
          computed_at: computed_at
        )
      end

      # ----- current --------------------------------------------------

      test "GET /score/current returns latest score when present" do
        older = build_score(score: 10, band: "low", computed_at: 2.days.ago)
        newer = build_score(score: 70, band: "high", computed_at: 1.hour.ago)

        get "/api/vendors/#{@vendor.id}/score/current", headers: acme_headers
        assert_equal 200, response.status, response.body
        payload = JSON.parse(response.body).fetch("score")
        assert_equal newer.id, payload["id"]
        assert_equal "high", payload["band"]
      end

      test "GET /score/current returns 404 when no scores exist" do
        get "/api/vendors/#{@vendor.id}/score/current", headers: acme_headers
        assert_equal 404, response.status
        assert_equal "NOT_FOUND", JSON.parse(response.body).dig("error", "code")
      end

      test "GET /score/current cross-tenant returns 404" do
        build_score
        get "/api/vendors/#{@vendor.id}/score/current", headers: globex_headers
        assert_equal 404, response.status
      end

      # ----- history --------------------------------------------------

      test "GET /score/history returns newest first" do
        s1 = build_score(computed_at: 2.days.ago, band: "low", score: 10)
        s2 = build_score(computed_at: 1.day.ago, band: "medium", score: 40)
        s3 = build_score(computed_at: Time.now.utc, band: "high", score: 70)

        get "/api/vendors/#{@vendor.id}/score/history", headers: acme_headers
        assert_equal 200, response.status
        json = JSON.parse(response.body)
        ids = json["scores"].map { |h| h["id"] }
        assert_equal [s3.id, s2.id, s1.id], ids
        assert_equal 3, json.dig("pagination", "total_count")
      end

      test "GET /score/history respects from/to filters" do
        build_score(computed_at: 10.days.ago)
        middle = build_score(computed_at: 5.days.ago)
        build_score(computed_at: 1.day.ago)

        get "/api/vendors/#{@vendor.id}/score/history",
            params: { from: 7.days.ago.iso8601, to: 2.days.ago.iso8601 },
            headers: acme_headers
        assert_equal 200, response.status
        json = JSON.parse(response.body)
        assert_equal 1, json["scores"].size
        assert_equal middle.id, json["scores"].first["id"]
      end

      test "GET /score/history with no scores returns empty array + pagination meta" do
        get "/api/vendors/#{@vendor.id}/score/history", headers: acme_headers
        assert_equal 200, response.status
        json = JSON.parse(response.body)
        assert_equal [], json["scores"]
        assert_equal 0, json.dig("pagination", "total_count")
      end

      test "GET /score/history cross-tenant returns 404" do
        build_score
        get "/api/vendors/#{@vendor.id}/score/history", headers: globex_headers
        assert_equal 404, response.status
      end
    end
  end
end
