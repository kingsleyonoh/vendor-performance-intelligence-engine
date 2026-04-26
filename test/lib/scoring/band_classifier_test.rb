# frozen_string_literal: true

require "test_helper"

# Scoring::BandClassifier — PRD §5.4. Pure-function classifier mapping a
# composite_score (0..100) + `band_thresholds` hash ({low_max, medium_max,
# high_max} per PRD §4.7) to a band symbol (:low | :medium | :high | :critical).
#
# Higher composite_score = higher risk (PRD §4.7). Score exactly equal to a
# threshold → lower band (`<=` semantics). Invalid threshold shapes raise
# ArgumentError.
class BandClassifierTest < ActiveSupport::TestCase
  THRESHOLDS = { low_max: 25.0, medium_max: 50.0, high_max: 75.0 }.freeze

  # ---------------- 4 bands ----------------

  test "score 0.0 → :low" do
    assert_equal :low,
      Scoring::BandClassifier.classify(composite_score: 0.0, band_thresholds: THRESHOLDS)
  end

  test "score 10 → :low" do
    assert_equal :low,
      Scoring::BandClassifier.classify(composite_score: 10.0, band_thresholds: THRESHOLDS)
  end

  test "score 30 → :medium" do
    assert_equal :medium,
      Scoring::BandClassifier.classify(composite_score: 30.0, band_thresholds: THRESHOLDS)
  end

  test "score 60 → :high" do
    assert_equal :high,
      Scoring::BandClassifier.classify(composite_score: 60.0, band_thresholds: THRESHOLDS)
  end

  test "score 85 → :critical" do
    assert_equal :critical,
      Scoring::BandClassifier.classify(composite_score: 85.0, band_thresholds: THRESHOLDS)
  end

  test "score 100 → :critical" do
    assert_equal :critical,
      Scoring::BandClassifier.classify(composite_score: 100.0, band_thresholds: THRESHOLDS)
  end

  # ---------------- boundary edges (exactly-equal = lower band) ----------------

  test "score exactly low_max (25.0) → :low" do
    assert_equal :low,
      Scoring::BandClassifier.classify(composite_score: 25.0, band_thresholds: THRESHOLDS)
  end

  test "score just above low_max (25.001) → :medium" do
    assert_equal :medium,
      Scoring::BandClassifier.classify(composite_score: 25.001, band_thresholds: THRESHOLDS)
  end

  test "score exactly medium_max (50.0) → :medium" do
    assert_equal :medium,
      Scoring::BandClassifier.classify(composite_score: 50.0, band_thresholds: THRESHOLDS)
  end

  test "score just above medium_max (50.001) → :high" do
    assert_equal :high,
      Scoring::BandClassifier.classify(composite_score: 50.001, band_thresholds: THRESHOLDS)
  end

  test "score exactly high_max (75.0) → :high" do
    assert_equal :high,
      Scoring::BandClassifier.classify(composite_score: 75.0, band_thresholds: THRESHOLDS)
  end

  test "score just above high_max (75.001) → :critical" do
    assert_equal :critical,
      Scoring::BandClassifier.classify(composite_score: 75.001, band_thresholds: THRESHOLDS)
  end

  # ---------------- threshold shapes: string-keyed hashes accepted ----------------

  test "accepts string-keyed band_thresholds (jsonb round-trip)" do
    # scoring_rules.band_thresholds comes back from Postgres JSONB as
    # string keys, not symbol keys. Classifier MUST accept both.
    result = Scoring::BandClassifier.classify(
      composite_score: 60.0,
      band_thresholds: { "low_max" => 25.0, "medium_max" => 50.0, "high_max" => 75.0 }
    )
    assert_equal :high, result
  end

  # ---------------- invalid threshold shapes raise ----------------

  test "raises ArgumentError when thresholds are not strictly ascending" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(
        composite_score: 50.0,
        band_thresholds: { low_max: 50.0, medium_max: 50.0, high_max: 75.0 }
      )
    end
  end

  test "raises ArgumentError when medium_max > high_max" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(
        composite_score: 10.0,
        band_thresholds: { low_max: 25.0, medium_max: 80.0, high_max: 75.0 }
      )
    end
  end

  test "raises ArgumentError when low_max is negative" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(
        composite_score: 10.0,
        band_thresholds: { low_max: -5.0, medium_max: 50.0, high_max: 75.0 }
      )
    end
  end

  test "raises ArgumentError when high_max > 100" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(
        composite_score: 10.0,
        band_thresholds: { low_max: 25.0, medium_max: 50.0, high_max: 120.0 }
      )
    end
  end

  test "raises ArgumentError when a threshold key is missing" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(
        composite_score: 10.0,
        band_thresholds: { low_max: 25.0, medium_max: 50.0 }
      )
    end
  end

  test "raises ArgumentError when band_thresholds is nil" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(composite_score: 10.0, band_thresholds: nil)
    end
  end

  test "raises ArgumentError when composite_score is nil" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(composite_score: nil, band_thresholds: THRESHOLDS)
    end
  end

  test "raises ArgumentError when composite_score out of [0, 100]" do
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(composite_score: 101.0, band_thresholds: THRESHOLDS)
    end
    assert_raises(ArgumentError) do
      Scoring::BandClassifier.classify(composite_score: -0.5, band_thresholds: THRESHOLDS)
    end
  end
end
