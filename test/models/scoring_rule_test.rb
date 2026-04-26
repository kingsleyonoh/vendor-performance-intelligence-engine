# frozen_string_literal: true

require "test_helper"

# ScoringRule — PRD §4.7. Per-tenant declarative configuration. One active
# rule per tenant enforced by partial unique index.
class ScoringRuleTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
  end

  def valid_attrs(overrides = {})
    {
      tenant: @acme,
      name: "Default v1",
      is_active: false,
      category_weights: {
        "financial" => 0.35,
        "operational" => 0.15,
        "contractual" => 0.30,
        "integration" => 0.15,
        "transactional" => 0.05
      },
      signal_weight_overrides: {},
      band_thresholds: {
        "low_max" => 25.0,
        "medium_max" => 50.0,
        "high_max" => 75.0
      },
      window_days: 90,
      time_decay_half_life_days: 45
    }.merge(overrides)
  end

  test "valid with defaults" do
    r = ScoringRule.new(valid_attrs)
    assert r.valid?, r.errors.full_messages.to_sentence
    assert r.save
  end

  test "name is required" do
    r = ScoringRule.new(valid_attrs(name: nil))
    assert_not r.valid?
  end

  test "category_weights must sum to ~1.00" do
    r = ScoringRule.new(valid_attrs(category_weights: {
      "financial" => 0.50,
      "operational" => 0.50,
      "contractual" => 0.50,
      "integration" => 0.50,
      "transactional" => 0.50
    }))
    assert_not r.valid?
    assert_includes r.errors[:category_weights].to_sentence, "sum"
  end

  test "category_weights must include all 5 canonical category keys" do
    r = ScoringRule.new(valid_attrs(category_weights: {
      "financial" => 0.50,
      "contractual" => 0.50
    }))
    assert_not r.valid?
  end

  test "band_thresholds must include all 3 keys" do
    r = ScoringRule.new(valid_attrs(band_thresholds: { "low_max" => 25.0 }))
    assert_not r.valid?
  end

  test "band_thresholds must be ascending" do
    r = ScoringRule.new(valid_attrs(band_thresholds: {
      "low_max" => 75.0, "medium_max" => 50.0, "high_max" => 25.0
    }))
    assert_not r.valid?
  end

  test "window_days must be positive" do
    r = ScoringRule.new(valid_attrs(window_days: 0))
    assert_not r.valid?
  end

  test "time_decay_half_life_days must be positive" do
    r = ScoringRule.new(valid_attrs(time_decay_half_life_days: 0))
    assert_not r.valid?
  end

  test "only one active rule per tenant: activating another deactivates the first" do
    first = ScoringRule.create!(valid_attrs(name: "Rule A", is_active: true))
    assert first.is_active

    second = ScoringRule.create!(valid_attrs(name: "Rule B", is_active: true))
    assert second.is_active
    assert_not first.reload.is_active,
               "activating Rule B must deactivate Rule A within the same tenant"
  end

  test "activated_at set when flipping is_active true" do
    r = ScoringRule.create!(valid_attrs(name: "Rule X", is_active: false))
    assert_nil r.activated_at

    r.update!(is_active: true)
    assert_not_nil r.activated_at
  end

  test "multiple inactive rules per tenant allowed" do
    ScoringRule.create!(valid_attrs(name: "A"))
    ScoringRule.create!(valid_attrs(name: "B"))
    assert_equal 2, ScoringRule.where(tenant: @acme, is_active: false).count
  end

  test "tenant-isolation: each tenant can have its own active rule" do
    acme_rule = ScoringRule.create!(valid_attrs(tenant: @acme, is_active: true))
    globex_rule = ScoringRule.create!(valid_attrs(tenant: @globex, is_active: true))
    assert acme_rule.is_active
    assert globex_rule.is_active
  end

  test "cross-tenant lookup scope check" do
    r = ScoringRule.create!(valid_attrs)
    assert_nil ScoringRule.where(tenant_id: @globex.id).find_by(id: r.id)
  end
end
