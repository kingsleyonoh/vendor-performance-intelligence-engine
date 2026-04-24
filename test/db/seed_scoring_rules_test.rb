# frozen_string_literal: true

require "test_helper"

# db/seeds.rb creates a default active scoring_rule for every persistent
# tenant in the database. Re-running the seed MUST NOT create duplicates.
class SeedScoringRulesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  i_suck_and_my_tests_are_order_dependent!

  setup do
    ScoringRule.delete_all
  end

  teardown do
    ScoringRule.delete_all
  end

  test "seeding creates one active default rule per tenant" do
    # Two fixture tenants exist (acme_gmbh_de + globex_inc_us).
    Rails.application.load_seed

    Tenant.find_each do |t|
      rules = ScoringRule.where(tenant_id: t.id, name: "Default v1")
      assert_equal 1, rules.count, "tenant #{t.slug} should have exactly one 'Default v1' rule"
      assert rules.first.is_active, "Default v1 must be active for tenant #{t.slug}"
    end
  end

  test "seeding is idempotent: three runs produce identical row count" do
    Rails.application.load_seed
    count_1 = ScoringRule.count

    Rails.application.load_seed
    Rails.application.load_seed
    assert_equal count_1, ScoringRule.count
  end

  test "default rule has the expected category weights + band thresholds" do
    Rails.application.load_seed
    r = ScoringRule.where(name: "Default v1").first

    weights = r.category_weights.transform_keys(&:to_s)
    assert_in_delta 1.00, weights.values.map(&:to_f).sum, 0.01
    assert weights.key?("financial")
    assert weights.key?("operational")
    assert weights.key?("contractual")
    assert weights.key?("integration")
    assert weights.key?("transactional")

    thresholds = r.band_thresholds.transform_keys(&:to_s)
    assert thresholds["low_max"].to_f < thresholds["medium_max"].to_f
    assert thresholds["medium_max"].to_f < thresholds["high_max"].to_f

    assert_equal 90, r.window_days
    assert_equal 45, r.time_decay_half_life_days
  end
end
