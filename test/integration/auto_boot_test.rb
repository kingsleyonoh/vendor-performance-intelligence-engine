# frozen_string_literal: true

require "test_helper"

# Tests for `config/initializers/auto_boot.rb` — PRD §11, §14.
#
# The initializer runs at Rails boot time (cannot be re-triggered at test
# runtime without reloading the whole app), so we verify its _contents_ via
# direct invocation: it must read AUTO_MIGRATE + AUTO_SEED, run the
# corresponding rake tasks idempotently, and never crash when flags are off.
class AutoBootTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @initializer_path = Rails.root.join("config/initializers/auto_boot.rb")
  end

  test "initializer file exists and defines AutoBoot module" do
    assert File.exist?(@initializer_path), "expected config/initializers/auto_boot.rb"
    source = File.read(@initializer_path)
    assert_match(/AUTO_MIGRATE/, source, "initializer must reference AUTO_MIGRATE")
    assert_match(/AUTO_SEED/, source, "initializer must reference AUTO_SEED")
  end

  test "AutoBoot.run with both flags false is a no-op" do
    ENV["AUTO_MIGRATE"] = "false"
    ENV["AUTO_SEED"] = "false"

    load @initializer_path.to_s
    # Should not raise.
    assert_nothing_raised { ::AutoBoot.run }
  ensure
    ENV.delete("AUTO_MIGRATE")
    ENV.delete("AUTO_SEED")
  end

  test "AutoBoot.run with AUTO_SEED=true is idempotent" do
    ENV["AUTO_MIGRATE"] = "false" # DB already migrated by test:prepare
    ENV["AUTO_SEED"] = "true"

    load @initializer_path.to_s

    before = SignalDefinition.count

    # Capture stdout from the rake task to avoid cluttering test output.
    capture_io { ::AutoBoot.run }
    capture_io { ::AutoBoot.run }

    after = SignalDefinition.count
    assert_equal before, after, "seed reruns must be idempotent"
  ensure
    ENV.delete("AUTO_MIGRATE")
    ENV.delete("AUTO_SEED")
  end
end
