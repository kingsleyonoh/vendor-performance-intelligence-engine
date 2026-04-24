# frozen_string_literal: true

require "test_helper"

# VendorScore — PRD §4.6. Composite score snapshots. Higher = higher risk.
class VendorScoreTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Supplier")
    @globex_vendor = Vendor.create!(tenant: @globex, canonical_name: "Globex Supplier")
    @rule = ScoringRule.create!(
      tenant: @acme,
      name: "Test Rule",
      is_active: true,
      category_weights: {
        "financial" => 0.35, "operational" => 0.15,
        "contractual" => 0.30, "integration" => 0.15,
        "transactional" => 0.05
      },
      band_thresholds: { "low_max" => 25.0, "medium_max" => 50.0, "high_max" => 75.0 },
      window_days: 90,
      time_decay_half_life_days: 45
    )
  end

  def valid_attrs(overrides = {})
    {
      tenant: @acme,
      vendor: @acme_vendor,
      scoring_rules_id: @rule.id,
      composite_score: 42.500,
      band: "medium",
      trend: "new",
      category_scores: {
        "financial" => 40.0, "operational" => 50.0,
        "contractual" => 30.0, "integration" => 50.0,
        "transactional" => 60.0
      },
      top_contributors: [
        { "signal_code" => "invoice.late_ratio_30d", "contribution_pct" => 22.4, "value" => 0.085 }
      ],
      window_days: 90,
      signals_considered_count: 12
    }.merge(overrides)
  end

  test "valid with minimal required attributes" do
    s = VendorScore.new(valid_attrs)
    assert s.valid?, s.errors.full_messages.to_sentence
    assert s.save
  end

  test "composite_score must be in 0..100" do
    assert_not VendorScore.new(valid_attrs(composite_score: -1)).valid?
    assert_not VendorScore.new(valid_attrs(composite_score: 101)).valid?
  end

  test "band must be in enum" do
    s = VendorScore.new(valid_attrs(band: "nonsense"))
    assert_not s.valid?
  end

  test "band accepts all 4 values" do
    %w[low medium high critical].each do |b|
      s = VendorScore.new(valid_attrs(band: b))
      assert s.valid?, "band=#{b} must be valid: #{s.errors.full_messages}"
    end
  end

  test "trend accepts all 4 values" do
    %w[improving stable degrading new].each do |t|
      s = VendorScore.new(valid_attrs(trend: t))
      assert s.valid?
    end
  end

  test "trend must be in enum" do
    s = VendorScore.new(valid_attrs(trend: "bogus"))
    assert_not s.valid?
  end

  test "category_scores must include all 5 categories" do
    s = VendorScore.new(valid_attrs(category_scores: { "financial" => 10.0 }))
    assert_not s.valid?
  end

  test "top_contributors length <= 5" do
    many = 6.times.map { |i| { "signal_code" => "x.#{i}", "contribution_pct" => 1.0, "value" => 0.0 } }
    s = VendorScore.new(valid_attrs(top_contributors: many))
    assert_not s.valid?
  end

  test "scoring_rules_id FK is required" do
    s = VendorScore.new(valid_attrs(scoring_rules_id: nil))
    assert_not s.valid?
  end

  test "latest_for returns newest score for a vendor" do
    older = VendorScore.create!(valid_attrs(composite_score: 10))
    older.update_columns(computed_at: 2.hours.ago)
    newer = VendorScore.create!(valid_attrs(composite_score: 80))

    latest = VendorScore.latest_for(@acme_vendor).first
    assert_equal newer.id, latest.id
  end

  test "tenant-isolation: globex cannot see acme's score" do
    s = VendorScore.create!(valid_attrs)
    assert_nil VendorScore.where(tenant_id: @globex.id).find_by(id: s.id)
  end

  test "top_contributors defaults to empty array when unspecified" do
    s = VendorScore.create!(valid_attrs(top_contributors: []))
    assert_equal [], s.reload.top_contributors
  end
end
