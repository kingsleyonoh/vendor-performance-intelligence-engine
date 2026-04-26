# frozen_string_literal: true

require "test_helper"

# Scoring::TimeDecay — PRD §5.4. Pure exponential decay used to weight
# older signals less: weight = 0.5 ^ (age_days / half_life_days).
class TimeDecayTest < ActiveSupport::TestCase
  test "age=0 → weight 1.0" do
    assert_in_delta 1.0, Scoring::TimeDecay.weight(age_days: 0, half_life_days: 45), 0.0001
  end

  test "age=half_life → weight 0.5" do
    assert_in_delta 0.5, Scoring::TimeDecay.weight(age_days: 45, half_life_days: 45), 0.0001
  end

  test "age=2*half_life → weight 0.25" do
    assert_in_delta 0.25, Scoring::TimeDecay.weight(age_days: 90, half_life_days: 45), 0.0001
  end

  test "age=4*half_life → weight 0.0625" do
    assert_in_delta 0.0625, Scoring::TimeDecay.weight(age_days: 180, half_life_days: 45), 0.0001
  end

  test "age=0.5*half_life → weight sqrt(0.5)" do
    assert_in_delta Math.sqrt(0.5),
      Scoring::TimeDecay.weight(age_days: 22.5, half_life_days: 45),
      0.0001
  end

  test "negative age clamps to 0 (returns 1.0)" do
    assert_in_delta 1.0, Scoring::TimeDecay.weight(age_days: -10, half_life_days: 45), 0.0001
  end

  test "half_life_days = 0 raises ArgumentError" do
    assert_raises(ArgumentError) do
      Scoring::TimeDecay.weight(age_days: 10, half_life_days: 0)
    end
  end

  test "half_life_days negative raises ArgumentError" do
    assert_raises(ArgumentError) do
      Scoring::TimeDecay.weight(age_days: 10, half_life_days: -5)
    end
  end

  test "apply multiplies value by weight" do
    result = Scoring::TimeDecay.apply(value: 80.0, age_days: 45, half_life_days: 45)
    assert_in_delta 40.0, result, 0.0001
  end

  test "apply at age=0 returns value unchanged" do
    result = Scoring::TimeDecay.apply(value: 50.0, age_days: 0, half_life_days: 45)
    assert_in_delta 50.0, result, 0.0001
  end
end
