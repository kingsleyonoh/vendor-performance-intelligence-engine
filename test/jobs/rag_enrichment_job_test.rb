# frozen_string_literal: true

require "test_helper"

# RagEnrichmentJob — PRD §5.7, §6.7, §7, §13.3.
#
# Nightly cron (`0 3 * * *` UTC). For each vendor with
# `metadata.rag_document_count > 0`, calls
# `Ecosystem::RagPlatformClient#fetch_entities(name: vendor.normalized_name)`
# and stores the result under `vendors.metadata.rag_enrichment`. Edge
# cases:
# - Zero entities → clear prior enrichment (set to {entities: [], fetched_at:})
# - Failure (5xx → TransientFailure / 4xx :failed / breaker open) → log + skip
#   that vendor; never crash the job. Other vendors continue.
# - Feature flag off → no-op, no DB writes.
class RagEnrichmentJobTest < ActiveJob::TestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @prev_rag_instance = Ecosystem::RagPlatformClient.instance
    @sent_calls = []
    @stub_responses = {} # name => response hash
  end

  teardown do
    Current.tenant = nil
    Ecosystem::RagPlatformClient.instance = @prev_rag_instance
  end

  test "feature flag off — no-op, no client calls" do
    install_rag_stub!
    vendor = create_indexed_vendor!(tenant: @acme, name: "Alpha Maschinenbau AG", normalized: "alpha")

    with_rag_disabled do
      RagEnrichmentJob.new.perform
    end

    assert_equal 0, @sent_calls.length
    vendor.reload
    refute vendor.metadata["rag_enrichment"], "should not write enrichment when feature off"
  end

  test "indexed vendor — fetches entities, stores in metadata.rag_enrichment" do
    install_rag_stub!
    vendor = create_indexed_vendor!(tenant: @acme, name: "Alpha", normalized: "alpha co")
    @stub_responses["alpha co"] = {
      status: :ok, response_code: 200,
      entities: [{ "id" => "e1", "name" => "Alpha Holdings", "type" => "parent" }]
    }

    with_rag_enabled do
      RagEnrichmentJob.new.perform
    end

    assert_equal ["alpha co"], @sent_calls
    vendor.reload
    enrichment = vendor.metadata["rag_enrichment"]
    assert enrichment, "expected metadata.rag_enrichment to be set"
    assert_equal 1, enrichment["entities"].length
    assert_equal "Alpha Holdings", enrichment["entities"].first["name"]
    assert enrichment["fetched_at"].present?
  end

  test "non-indexed vendor (rag_document_count missing or 0) — skipped" do
    install_rag_stub!
    Vendor.create!(
      tenant: @acme,
      canonical_name: "Beta NoRag Co",
      tax_id: "DE-RAG-2-#{SecureRandom.hex(2)}",
      country_code: "DE",
      status: "active",
      metadata: {}  # no rag_document_count
    )
    Vendor.create!(
      tenant: @acme,
      canonical_name: "Beta Zero Rag Co",
      tax_id: "DE-RAG-3-#{SecureRandom.hex(2)}",
      country_code: "DE",
      status: "active",
      metadata: { "rag_document_count" => 0 }
    )

    with_rag_enabled do
      RagEnrichmentJob.new.perform
    end

    assert_equal 0, @sent_calls.length, "non-indexed vendors should be skipped entirely"
  end

  test "zero entities returned — clears prior enrichment" do
    install_rag_stub!
    vendor = create_indexed_vendor!(
      tenant: @acme, name: "Alpha", normalized: "alpha co",
      extra: { "rag_enrichment" => { "entities" => [{ "id" => "stale" }], "fetched_at" => "2020-01-01" } }
    )
    @stub_responses["alpha co"] = { status: :ok, response_code: 200, entities: [] }

    with_rag_enabled do
      RagEnrichmentJob.new.perform
    end

    vendor.reload
    enrichment = vendor.metadata["rag_enrichment"]
    assert_equal [], enrichment["entities"]
    assert enrichment["fetched_at"].present?
    refute_equal "2020-01-01", enrichment["fetched_at"], "fetched_at should be refreshed"
  end

  test "5xx (TransientFailure) — vendor skipped, other vendors continue" do
    install_rag_stub!
    bad   = create_indexed_vendor!(tenant: @acme, name: "Bad",  normalized: "bad co")
    good  = create_indexed_vendor!(tenant: @acme, name: "Good", normalized: "good co", tax_id_suffix: "G")
    @stub_responses["bad co"]  = :raise_transient
    @stub_responses["good co"] = { status: :ok, response_code: 200, entities: [{ "id" => "ok" }] }

    with_rag_enabled do
      assert_nothing_raised do
        RagEnrichmentJob.new.perform
      end
    end

    bad.reload
    good.reload
    refute bad.metadata["rag_enrichment"], "failed vendor should not have enrichment written"
    assert good.metadata["rag_enrichment"], "successful vendor should have enrichment written"
  end

  test "cross-tenant fan-out — both tenants' vendors are processed" do
    install_rag_stub!
    create_indexed_vendor!(tenant: @acme,   name: "Alpha", normalized: "alpha co")
    create_indexed_vendor!(tenant: @globex, name: "Eta",   normalized: "eta co", tax_id_suffix: "E")
    @stub_responses["alpha co"] = { status: :ok, response_code: 200, entities: [] }
    @stub_responses["eta co"]   = { status: :ok, response_code: 200, entities: [] }

    with_rag_enabled do
      RagEnrichmentJob.new.perform
    end

    assert_equal 2, @sent_calls.length
    assert_includes @sent_calls, "alpha co"
    assert_includes @sent_calls, "eta co"
  end

  # ============================== Helpers ==============================

  private

  def install_rag_stub!
    test_self = self
    stub = Object.new
    stub.define_singleton_method(:enabled?) do
      ENV.fetch("RAG_PLATFORM_ENABLED", "false").to_s.downcase == "true"
    end
    stub.define_singleton_method(:fetch_entities) do |name:|
      next { status: :skipped, reason: "RAG Platform disabled" } unless enabled?
      test_self.instance_variable_get(:@sent_calls) << name
      response = test_self.instance_variable_get(:@stub_responses)[name]
      raise Ecosystem::TransientFailure, "stub transient" if response == :raise_transient
      response || { status: :ok, response_code: 200, entities: [] }
    end
    Ecosystem::RagPlatformClient.instance = stub
  end

  def with_rag_enabled
    prev = ENV["RAG_PLATFORM_ENABLED"]
    ENV["RAG_PLATFORM_ENABLED"] = "true"
    yield
  ensure
    ENV["RAG_PLATFORM_ENABLED"] = prev
  end

  def with_rag_disabled
    prev = ENV["RAG_PLATFORM_ENABLED"]
    ENV["RAG_PLATFORM_ENABLED"] = "false"
    yield
  ensure
    ENV["RAG_PLATFORM_ENABLED"] = prev
  end

  def create_indexed_vendor!(tenant:, name:, normalized:, tax_id_suffix: "X", extra: {})
    metadata = { "rag_document_count" => 5 }.merge(extra)
    # Use the canonical_name that the NameNormalizer will turn into the
    # passed `normalized` key. The model's before_validation callback
    # rewrites normalized_name from canonical_name, so we feed it the
    # exact string the normalizer would emit.
    canonical = "#{normalized.titleize} Operating Co"
    v = Vendor.new(
      tenant: tenant,
      canonical_name: canonical,
      tax_id: "DE-RAG-#{tax_id_suffix}-#{SecureRandom.hex(2)}",
      country_code: "DE",
      status: "active",
      metadata: metadata
    )
    v.save!
    # Override normalized_name AFTER save (bypassing the callback) so the
    # test can pin an exact normalized key for stub matching.
    v.update_columns(normalized_name: normalized)
    v.reload
  end
end
