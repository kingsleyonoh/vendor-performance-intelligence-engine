# frozen_string_literal: true

require "test_helper"

# Scoring::SignalScalers — PRD §5.4. Pure-function registry that maps a raw
# signal value + its value_type + direction to a 0..100 risk contribution
# (where 100 = worst-case risk, 0 = ideal).
class SignalScalersTest < ActiveSupport::TestCase
  # ---------------- rate ----------------

  test "rate higher_is_worse: 0.0 → 0.0" do
    assert_in_delta 0.0,
      Scoring::SignalScalers.scale(value: 0.0, value_type: "rate", direction: "higher_is_worse"),
      0.001
  end

  test "rate higher_is_worse: 1.0 → 100.0" do
    assert_in_delta 100.0,
      Scoring::SignalScalers.scale(value: 1.0, value_type: "rate", direction: "higher_is_worse"),
      0.001
  end

  test "rate higher_is_worse: 0.5 → 50.0" do
    assert_in_delta 50.0,
      Scoring::SignalScalers.scale(value: 0.5, value_type: "rate", direction: "higher_is_worse"),
      0.001
  end

  test "rate lower_is_worse: 0.0 → 100.0" do
    assert_in_delta 100.0,
      Scoring::SignalScalers.scale(value: 0.0, value_type: "rate", direction: "lower_is_worse"),
      0.001
  end

  test "rate lower_is_worse: 1.0 → 0.0" do
    assert_in_delta 0.0,
      Scoring::SignalScalers.scale(value: 1.0, value_type: "rate", direction: "lower_is_worse"),
      0.001
  end

  test "rate input > 1.0 clamps to 1.0 (no raise)" do
    result = Scoring::SignalScalers.scale(value: 1.7, value_type: "rate", direction: "higher_is_worse")
    assert_in_delta 100.0, result, 0.001
  end

  test "rate input < 0 clamps to 0" do
    result = Scoring::SignalScalers.scale(value: -0.5, value_type: "rate", direction: "higher_is_worse")
    assert_in_delta 0.0, result, 0.001
  end

  # ---------------- count ----------------

  test "count higher_is_worse at min → 0" do
    assert_in_delta 0.0,
      Scoring::SignalScalers.scale(value: 0, value_type: "count",
                                   direction: "higher_is_worse",
                                   min_value: 0, max_value: 10),
      0.001
  end

  test "count higher_is_worse at max → 100" do
    assert_in_delta 100.0,
      Scoring::SignalScalers.scale(value: 10, value_type: "count",
                                   direction: "higher_is_worse",
                                   min_value: 0, max_value: 10),
      0.001
  end

  test "count higher_is_worse at midpoint → 50" do
    assert_in_delta 50.0,
      Scoring::SignalScalers.scale(value: 5, value_type: "count",
                                   direction: "higher_is_worse",
                                   min_value: 0, max_value: 10),
      0.001
  end

  test "count out-of-range clamps to min/max (no raise)" do
    low = Scoring::SignalScalers.scale(value: -100, value_type: "count",
                                       direction: "higher_is_worse",
                                       min_value: 0, max_value: 10)
    high = Scoring::SignalScalers.scale(value: 9_999, value_type: "count",
                                        direction: "higher_is_worse",
                                        min_value: 0, max_value: 10)
    assert_in_delta 0.0, low, 0.001
    assert_in_delta 100.0, high, 0.001
  end

  test "count missing min_value raises ArgumentError" do
    assert_raises(ArgumentError) do
      Scoring::SignalScalers.scale(value: 5, value_type: "count",
                                   direction: "higher_is_worse",
                                   max_value: 10)
    end
  end

  test "count missing max_value raises ArgumentError" do
    assert_raises(ArgumentError) do
      Scoring::SignalScalers.scale(value: 5, value_type: "count",
                                   direction: "higher_is_worse",
                                   min_value: 0)
    end
  end

  # ---------------- boolean ----------------

  test "boolean higher_is_worse + true → 100" do
    assert_in_delta 100.0,
      Scoring::SignalScalers.scale(value: true, value_type: "boolean", direction: "higher_is_worse"),
      0.001
  end

  test "boolean higher_is_worse + false → 0" do
    assert_in_delta 0.0,
      Scoring::SignalScalers.scale(value: false, value_type: "boolean", direction: "higher_is_worse"),
      0.001
  end

  test "boolean lower_is_worse + true → 0" do
    assert_in_delta 0.0,
      Scoring::SignalScalers.scale(value: true, value_type: "boolean", direction: "lower_is_worse"),
      0.001
  end

  test "boolean lower_is_worse + false → 100" do
    assert_in_delta 100.0,
      Scoring::SignalScalers.scale(value: false, value_type: "boolean", direction: "lower_is_worse"),
      0.001
  end

  # ---------------- duration_seconds ----------------

  test "duration_seconds higher_is_worse scales like count" do
    result = Scoring::SignalScalers.scale(value: 30 * 86400,
                                          value_type: "duration_seconds",
                                          direction: "higher_is_worse",
                                          min_value: 1 * 86400,
                                          max_value: 90 * 86400)
    # (30-1)/(90-1) = 29/89 ≈ 0.3258 → 32.58
    assert_in_delta 32.58, result, 0.1
  end

  test "duration_seconds missing bounds raises" do
    assert_raises(ArgumentError) do
      Scoring::SignalScalers.scale(value: 10, value_type: "duration_seconds",
                                   direction: "higher_is_worse")
    end
  end

  # ---------------- money_cents ----------------

  test "money_cents higher_is_worse scales like count" do
    result = Scoring::SignalScalers.scale(value: 50_000, value_type: "money_cents",
                                          direction: "higher_is_worse",
                                          min_value: 0, max_value: 100_000)
    assert_in_delta 50.0, result, 0.001
  end

  test "money_cents missing bounds raises" do
    assert_raises(ArgumentError) do
      Scoring::SignalScalers.scale(value: 5_000, value_type: "money_cents",
                                   direction: "higher_is_worse")
    end
  end

  # ---------------- error paths ----------------

  test "unknown value_type raises ArgumentError" do
    assert_raises(ArgumentError) do
      Scoring::SignalScalers.scale(value: 0.5, value_type: "gibberish",
                                   direction: "higher_is_worse")
    end
  end

  test "unknown direction raises ArgumentError" do
    assert_raises(ArgumentError) do
      Scoring::SignalScalers.scale(value: 0.5, value_type: "rate",
                                   direction: "sideways")
    end
  end
end
