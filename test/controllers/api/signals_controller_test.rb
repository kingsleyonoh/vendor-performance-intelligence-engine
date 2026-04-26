# frozen_string_literal: true

require "test_helper"

# Tests for /api/signals ingestion — PRD §5.3, §8b.
# Cross-tenant scenarios MUST resolve to the caller's tenant (vendor
# resolver creates a vendor under caller, never leaks to another tenant).
module Api
  class SignalsControllerTest < ActionDispatch::IntegrationTest
    ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
    GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      @acme = tenants(:acme_gmbh_de)
      @globex = tenants(:globex_inc_us)

      # Parallel test workers get a fresh schema but do not load seeds.
      # The validator resolves signal_code against signal_definitions, so
      # seed the catalog on first use.
      ensure_signal_catalog_seeded

      # Seed the default scoring rule for both tenants so CompositeScorer
      # can resolve when the post_insert_hook runs (it does not run in
      # controller tests unless explicitly enabled — we rely on the default
      # no-op hook + an explicit inline scoring_rule per tenant).
      ensure_scoring_rule(@acme)
      ensure_scoring_rule(@globex)
    end

    def ensure_signal_catalog_seeded
      return if SignalDefinition.exists?

      yml = YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml"))
      yml.each { |row| SignalDefinition.create!(row) }
    end

    teardown do
      Current.tenant = nil
      Rails.cache = @previous_cache if @previous_cache
    end

    def ensure_scoring_rule(tenant)
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

    def single_payload(overrides = {})
      {
        vendor_ref: {
          normalized_name: "acme vendor co",
          tax_id: "DE111222333"
        },
        signal_code: "invoice.late_ratio_30d",
        source_system: "invoice_recon",
        source_event_id: "evt-#{SecureRandom.hex(4)}",
        value_numeric: 0.12,
        recorded_at: Time.now.utc.iso8601
      }.merge(overrides)
    end

    # --------------------------------------------------------------
    # Single signal
    # --------------------------------------------------------------

    test "POST /api/signals (single) returns 201 and persists a vendor_signal" do
      before = VendorSignal.count
      post "/api/signals", params: single_payload.to_json, headers: acme_headers
      assert_equal 201, response.status, response.body
      assert_equal before + 1, VendorSignal.count
      payload = JSON.parse(response.body).fetch("signal")
      assert_equal "invoice.late_ratio_30d", payload["signal_code"]
      # Signal must belong to caller's tenant
      assert_equal @acme.id, VendorSignal.find(payload["id"]).tenant_id
    end

    test "POST /api/signals (single) with invalid signal_code returns 400" do
      post "/api/signals", params: single_payload(signal_code: "not.a.real.code").to_json,
                           headers: acme_headers
      assert_equal 400, response.status
      body = JSON.parse(response.body)
      assert_equal "VALIDATION_ERROR", body.dig("error", "code")
    end

    test "POST /api/signals missing X-API-Key returns 401" do
      post "/api/signals", params: single_payload.to_json,
                           headers: { "Content-Type" => "application/json" }
      assert_equal 401, response.status
    end

    # --------------------------------------------------------------
    # Batch
    # --------------------------------------------------------------

    test "POST /api/signals (batch) returns 202 with aggregate counts" do
      body = {
        signals: [
          single_payload(source_event_id: "b1"),
          single_payload(source_event_id: "b2"),
          single_payload(source_event_id: "b3")
        ]
      }
      post "/api/signals", params: body.to_json, headers: acme_headers
      assert_equal 202, response.status, response.body
      json = JSON.parse(response.body)
      assert_equal 3, json["accepted_count"]
      assert_equal 0, json["rejected_count"]
      assert_equal 0, json["deduped_count"]
      assert_equal 3, json["results"].size
      json["results"].each { |r| assert_equal "ingested", r["status"] }
    end

    test "POST /api/signals (batch) with 1 invalid signal returns mixed results" do
      body = {
        signals: [
          single_payload(source_event_id: "mix1"),
          single_payload(source_event_id: "mix2", signal_code: "unknown.code"),
          single_payload(source_event_id: "mix3")
        ]
      }
      post "/api/signals", params: body.to_json, headers: acme_headers
      assert_equal 202, response.status, response.body
      json = JSON.parse(response.body)
      assert_equal 2, json["accepted_count"]
      assert_equal 1, json["rejected_count"]
      statuses = json["results"].map { |r| r["status"] }
      assert_equal %w[ingested rejected ingested], statuses
      assert_equal "UNKNOWN_SIGNAL_CODE", json["results"][1]["rejection_reason"]
    end

    test "POST /api/signals (batch) over INGESTION_BATCH_SIZE returns 400" do
      oversize = { signals: Array.new(101) { |i| single_payload(source_event_id: "os-#{i}") } }
      post "/api/signals", params: oversize.to_json, headers: acme_headers
      assert_equal 400, response.status
      assert_equal "VALIDATION_ERROR", JSON.parse(response.body).dig("error", "code")
    end

    test "POST /api/signals (batch) duplicate source_event_id is deduped" do
      evt = "dup-evt-1"
      body = {
        signals: [
          single_payload(source_event_id: evt),
          single_payload(source_event_id: evt)
        ]
      }
      post "/api/signals", params: body.to_json, headers: acme_headers
      assert_equal 202, response.status
      json = JSON.parse(response.body)
      assert_equal 1, json["accepted_count"]
      assert_equal 1, json["deduped_count"]
      assert_equal 0, json["rejected_count"]
      # Only one row in DB
      assert_equal 1,
                   VendorSignal.where(tenant_id: @acme.id, source_event_id: evt).count
    end

    # --------------------------------------------------------------
    # Tenant isolation
    # --------------------------------------------------------------

    test "POST /api/signals signal resolves vendor under caller tenant only" do
      # Acme ingests → a vendor is auto-created under acme.
      post "/api/signals",
           params: single_payload(source_event_id: "iso-1",
                                  vendor_ref: { normalized_name: "shared name co", tax_id: "DE111111111" }).to_json,
           headers: acme_headers
      assert_equal 201, response.status

      # Globex ingests the same "name" → a separate vendor under globex.
      post "/api/signals",
           params: single_payload(source_event_id: "iso-2",
                                  vendor_ref: { normalized_name: "shared name co", tax_id: "DE111111111" }).to_json,
           headers: globex_headers
      assert_equal 201, response.status

      acme_vendors = Vendor.where(tenant_id: @acme.id, tax_id: "DE111111111").count
      globex_vendors = Vendor.where(tenant_id: @globex.id, tax_id: "DE111111111").count
      assert_equal 1, acme_vendors
      assert_equal 1, globex_vendors
    end

    # --------------------------------------------------------------
    # ScoreRecomputeJob wiring — relies on post_insert_hook set in
    # config/initializers/signal_ingester_hooks.rb
    # --------------------------------------------------------------

    test "POST /api/signals enqueues ScoreRecomputeJob after ingestion" do
      with_test_adapter do
        post "/api/signals", params: single_payload.to_json, headers: acme_headers
        assert_equal 201, response.status
        enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
        jobs = enqueued.select do |j|
          (j[:job] || j["job_class"]) .to_s == "ScoreRecomputeJob"
        end
        assert jobs.any?,
               "expected ScoreRecomputeJob enqueued, got #{enqueued.inspect}"
      end
    end

    private

    def with_test_adapter
      prev_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      yield
    ensure
      ActiveJob::Base.queue_adapter = prev_adapter
    end
  end
end
