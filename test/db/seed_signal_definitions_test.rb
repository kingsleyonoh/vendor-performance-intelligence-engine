# frozen_string_literal: true

require "test_helper"

# db/seeds.rb signal_definitions loader — PRD §4.4 + §13.1. Must be
# idempotent (spec §15 idempotence criterion) and produce a catalog whose
# default_weight sum stays balanced.
class SeedSignalDefinitionsTest < ActiveSupport::TestCase
  SEED_PATH = Rails.root.join("db", "seeds", "signal_definitions.yml")

  setup do
    # Do not touch any other records. Clear signal_definitions only.
    SignalDefinition.delete_all
  end

  test "seed file exists" do
    assert File.exist?(SEED_PATH), "Missing seed file at #{SEED_PATH}"
  end

  test "loading seeds inserts the catalog" do
    load_seeds!
    expected_count = YAML.load_file(SEED_PATH).length
    assert_equal expected_count, SignalDefinition.count
    assert SignalDefinition.count >= 15, "expected ≥15 signals seeded, got #{SignalDefinition.count}"
  end

  test "re-running seeds is idempotent" do
    load_seeds!
    count_after_first = SignalDefinition.count
    load_seeds!
    assert_equal count_after_first, SignalDefinition.count, "seeds not idempotent"
  end

  test "sum of default_weight across the catalog is approximately 1.00" do
    load_seeds!
    sum = SignalDefinition.sum(:default_weight).to_f
    assert_in_delta 1.0, sum, 0.01, "default_weight sum #{sum} not within 0.01 of 1.0"
  end

  test "every seeded row is valid" do
    load_seeds!
    SignalDefinition.find_each do |sd|
      assert sd.valid?, "#{sd.code} invalid: #{sd.errors.full_messages}"
    end
  end

  private

  def load_seeds!
    # Call the idempotent loader defined in db/seeds.rb
    Rails.application.load_seed
  end
end
