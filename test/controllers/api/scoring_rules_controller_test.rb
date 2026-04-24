# frozen_string_literal: true

require "test_helper"

# /api/scoring_rules — PRD §4.6, §5, §8b.
#
# CRUD + activate + preview. The preview endpoint must simulate band
# changes for a 10-vendor sample WITHOUT persisting any vendor_scores
# rows (PRD §15 #7).
module Api
  class ScoringRulesControllerTest < ActionDispatch::IntegrationTest
    ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
    GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @acme = tenants(:acme_gmbh_de)
      @globex = tenants(:globex_inc_us)
      ensure_signal_catalog
      @acme_rule = ensure_active_rule(@acme, name: "Default v1")
      @globex_rule = ensure_active_rule(@globex, name: "Default v1 (Globex)")
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

    # ----------------------------------------------------------------
    # Index / Show
    # ----------------------------------------------------------------

    test "GET /api/scoring_rules lists only caller's rules" do
      get "/api/scoring_rules", headers: acme_headers
      assert_equal 200, response.status
      body = JSON.parse(response.body)
      names = body.fetch("scoring_rules").map { |r| r["name"] }
      assert_includes names, "Default v1"
      refute_includes names, "Default v1 (Globex)"
    end

    test "GET /api/scoring_rules/:id returns the rule" do
      get "/api/scoring_rules/#{@acme_rule.id}", headers: acme_headers
      assert_equal 200, response.status
      rule = JSON.parse(response.body).fetch("scoring_rule")
      assert_equal @acme_rule.id, rule["id"]
      assert_equal true, rule["is_active"]
    end

    test "GET /api/scoring_rules/:id cross-tenant returns 404" do
      get "/api/scoring_rules/#{@acme_rule.id}", headers: globex_headers
      assert_equal 404, response.status
    end

    # ----------------------------------------------------------------
    # Create
    # ----------------------------------------------------------------

    test "POST /api/scoring_rules creates a draft rule (is_active=false)" do
      body = {
        name: "Tuning A",
        category_weights: { financial: 0.35, operational: 0.15, contractual: 0.30,
                            integration: 0.15, transactional: 0.05 },
        band_thresholds: { low_max: 25, medium_max: 50, high_max: 75 },
        window_days: 90,
        time_decay_half_life_days: 45,
        signal_weight_overrides: {}
      }
      post "/api/scoring_rules", params: body.to_json, headers: acme_headers
      assert_equal 201, response.status, response.body
      r = JSON.parse(response.body).fetch("scoring_rule")
      assert_equal false, r["is_active"]
      assert_equal "Tuning A", r["name"]
    end

    test "POST /api/scoring_rules rejects bad weights sum" do
      body = {
        name: "Bad Sum",
        category_weights: { financial: 0.5, operational: 0.5, contractual: 0.5,
                            integration: 0.5, transactional: 0.5 },
        band_thresholds: { low_max: 25, medium_max: 50, high_max: 75 },
        window_days: 90,
        time_decay_half_life_days: 45
      }
      post "/api/scoring_rules", params: body.to_json, headers: acme_headers
      assert_equal 400, response.status
      assert_equal "VALIDATION_ERROR", JSON.parse(response.body).dig("error", "code")
    end

    test "POST /api/scoring_rules rejects non-ascending thresholds" do
      body = {
        name: "Bad Thr",
        category_weights: { financial: 0.35, operational: 0.15, contractual: 0.30,
                            integration: 0.15, transactional: 0.05 },
        band_thresholds: { low_max: 60, medium_max: 50, high_max: 75 },
        window_days: 90,
        time_decay_half_life_days: 45
      }
      post "/api/scoring_rules", params: body.to_json, headers: acme_headers
      assert_equal 400, response.status
    end

    # ----------------------------------------------------------------
    # Update
    # ----------------------------------------------------------------

    test "PATCH /api/scoring_rules/:id updates a draft rule" do
      rule = ScoringRule.create!(
        tenant: @acme, name: "Draft Z",
        category_weights: { "financial" => 0.20, "operational" => 0.20,
                            "contractual" => 0.20, "integration" => 0.20,
                            "transactional" => 0.20 },
        band_thresholds: { "low_max" => 25, "medium_max" => 50, "high_max" => 75 },
        window_days: 90, time_decay_half_life_days: 45, is_active: false
      )
      patch "/api/scoring_rules/#{rule.id}",
            params: { window_days: 60 }.to_json,
            headers: acme_headers
      assert_equal 200, response.status, response.body
      assert_equal 60, rule.reload.window_days
    end

    # ----------------------------------------------------------------
    # Destroy
    # ----------------------------------------------------------------

    test "DELETE /api/scoring_rules/:id refuses to delete active rule → 409" do
      delete "/api/scoring_rules/#{@acme_rule.id}", headers: acme_headers
      assert_equal 409, response.status
    end

    test "DELETE /api/scoring_rules/:id deletes an inactive draft" do
      draft = ScoringRule.create!(
        tenant: @acme, name: "Throwaway",
        category_weights: { "financial" => 0.20, "operational" => 0.20,
                            "contractual" => 0.20, "integration" => 0.20,
                            "transactional" => 0.20 },
        band_thresholds: { "low_max" => 25, "medium_max" => 50, "high_max" => 75 },
        window_days: 90, time_decay_half_life_days: 45, is_active: false
      )
      delete "/api/scoring_rules/#{draft.id}", headers: acme_headers
      assert_equal 200, response.status
      refute ScoringRule.exists?(draft.id)
    end

    # ----------------------------------------------------------------
    # Activate
    # ----------------------------------------------------------------

    test "POST /api/scoring_rules/:id/activate atomically deactivates others" do
      other = ScoringRule.create!(
        tenant: @acme, name: "Candidate",
        category_weights: { "financial" => 0.40, "operational" => 0.10,
                            "contractual" => 0.30, "integration" => 0.15,
                            "transactional" => 0.05 },
        band_thresholds: { "low_max" => 25, "medium_max" => 50, "high_max" => 75 },
        window_days: 90, time_decay_half_life_days: 45, is_active: false
      )

      post "/api/scoring_rules/#{other.id}/activate", headers: acme_headers
      assert_equal 200, response.status, response.body

      @acme_rule.reload
      other.reload
      assert_equal true, other.is_active
      assert_equal false, @acme_rule.is_active
    end

    test "POST /api/scoring_rules/:id/activate fires on_activation_hooks" do
      other = ScoringRule.create!(
        tenant: @acme, name: "Activation Hook Target",
        category_weights: { "financial" => 0.40, "operational" => 0.10,
                            "contractual" => 0.30, "integration" => 0.15,
                            "transactional" => 0.05 },
        band_thresholds: { "low_max" => 25, "medium_max" => 50, "high_max" => 75 },
        window_days: 90, time_decay_half_life_days: 45, is_active: false
      )
      captured = []
      hook = ->(rule) { captured << rule.id }
      original = ::Api::ScoringRulesController.on_activation_hooks.dup
      ::Api::ScoringRulesController.on_activation_hooks << hook
      begin
        post "/api/scoring_rules/#{other.id}/activate", headers: acme_headers
        assert_equal 200, response.status
        assert_equal [other.id], captured
      ensure
        ::Api::ScoringRulesController.on_activation_hooks.replace(original)
      end
    end

    # ----------------------------------------------------------------
    # Preview
    # ----------------------------------------------------------------

    test "POST /api/scoring_rules/:id/preview does NOT persist vendor_scores" do
      # Seed 2 vendors with signals + prior scores
      v1 = Vendor.create!(tenant: @acme, canonical_name: "Prev Vendor 1")
      VendorSignal.create!(tenant: @acme, vendor: v1,
                           signal_code: "invoice.late_ratio_30d",
                           source_system: "invoice_recon",
                           source_event_id: "p1-evt",
                           value_numeric: 0.3,
                           recorded_at: 1.day.ago)
      seed_prior_score(@acme, v1, composite: 30.0, band: "medium")

      rule = ScoringRule.create!(
        tenant: @acme, name: "Preview Candidate",
        category_weights: { "financial" => 0.80, "operational" => 0.05,
                            "contractual" => 0.10, "integration" => 0.03,
                            "transactional" => 0.02 },
        band_thresholds: { "low_max" => 20, "medium_max" => 40, "high_max" => 60 },
        window_days: 90, time_decay_half_life_days: 45, is_active: false
      )

      score_count_before = VendorScore.where(tenant_id: @acme.id).count

      post "/api/scoring_rules/#{rule.id}/preview",
           params: { vendor_ids: [v1.id] }.to_json,
           headers: acme_headers

      assert_equal 200, response.status, response.body
      body = JSON.parse(response.body)
      previews = body.fetch("previews")
      assert previews.is_a?(Array)
      assert previews.any? { |p| p["vendor_id"] == v1.id }
      p1 = previews.find { |p| p["vendor_id"] == v1.id }
      assert p1.key?("current_band")
      assert p1.key?("new_band")
      assert p1.key?("new_composite")
      assert p1.key?("band_change")

      score_count_after = VendorScore.where(tenant_id: @acme.id).count
      assert_equal score_count_before, score_count_after,
                   "preview must not persist any vendor_scores rows"
    end

    test "POST /api/scoring_rules/:id/preview picks 10-vendor sample when vendor_ids omitted" do
      # Create 12 vendors, 5 of them with prior scores so the sampler has signal
      vendors = 12.times.map { |i|
        v = Vendor.create!(tenant: @acme, canonical_name: "Sample V#{i}")
        VendorSignal.create!(tenant: @acme, vendor: v,
                             signal_code: "invoice.late_ratio_30d",
                             source_system: "invoice_recon",
                             source_event_id: "sv-#{i}-#{SecureRandom.hex(2)}",
                             value_numeric: 0.1 + (i * 0.05),
                             recorded_at: 1.day.ago)
        seed_prior_score(@acme, v, composite: 50.0 + i, band: "medium") if i < 8
        v
      }

      rule = ScoringRule.create!(
        tenant: @acme, name: "Sample Candidate",
        category_weights: { "financial" => 0.35, "operational" => 0.15,
                            "contractual" => 0.30, "integration" => 0.15,
                            "transactional" => 0.05 },
        band_thresholds: { "low_max" => 25, "medium_max" => 50, "high_max" => 75 },
        window_days: 90, time_decay_half_life_days: 45, is_active: false
      )

      post "/api/scoring_rules/#{rule.id}/preview", params: {}.to_json, headers: acme_headers
      assert_equal 200, response.status, response.body
      body = JSON.parse(response.body)
      assert body.fetch("previews").size <= 10, "sample must be capped at 10"
      assert body.fetch("summary").key?("total_previewed")
      assert body.fetch("summary").key?("changed_count")
    end

    test "POST /api/scoring_rules/:id/preview cross-tenant returns 404" do
      post "/api/scoring_rules/#{@acme_rule.id}/preview",
           params: {}.to_json, headers: globex_headers
      assert_equal 404, response.status
    end

    # ----------------------------------------------------------------
    # Tenant isolation — all endpoints
    # ----------------------------------------------------------------

    test "tenant isolation on every endpoint" do
      # index — globex cannot see acme rule
      get "/api/scoring_rules", headers: globex_headers
      names = JSON.parse(response.body).fetch("scoring_rules").map { |r| r["name"] }
      refute_includes names, "Default v1"

      # show, patch, delete, activate → 404
      get "/api/scoring_rules/#{@acme_rule.id}", headers: globex_headers
      assert_equal 404, response.status

      patch "/api/scoring_rules/#{@acme_rule.id}",
            params: { window_days: 30 }.to_json, headers: globex_headers
      assert_equal 404, response.status

      delete "/api/scoring_rules/#{@acme_rule.id}", headers: globex_headers
      assert_equal 404, response.status

      post "/api/scoring_rules/#{@acme_rule.id}/activate", headers: globex_headers
      assert_equal 404, response.status
    end

    # ----------------------------------------------------------------
    # Helpers
    # ----------------------------------------------------------------

    private

    def ensure_signal_catalog
      return if SignalDefinition.exists?

      YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each do |row|
        SignalDefinition.create!(row)
      end
    end

    def ensure_active_rule(tenant, name:)
      existing = ScoringRule.where(tenant_id: tenant.id, is_active: true).first
      return existing if existing

      ScoringRule.create!(
        tenant: tenant, name: name, is_active: true,
        category_weights: { "financial" => 0.35, "operational" => 0.15,
                            "contractual" => 0.30, "integration" => 0.15,
                            "transactional" => 0.05 },
        band_thresholds: { "low_max" => 25.0, "medium_max" => 50.0, "high_max" => 75.0 },
        window_days: 90, time_decay_half_life_days: 45
      )
    end

    def seed_prior_score(tenant, vendor, composite:, band:)
      rule = ScoringRule.where(tenant_id: tenant.id, is_active: true).first!
      VendorScore.create!(
        tenant: tenant, vendor: vendor,
        scoring_rule: rule, composite_score: composite,
        band: band, trend: "new",
        category_scores: VendorScore::CATEGORIES.index_with { 0.0 },
        top_contributors: [], window_days: rule.window_days,
        signals_considered_count: 1, computed_at: 1.day.ago
      )
    end
  end
end
