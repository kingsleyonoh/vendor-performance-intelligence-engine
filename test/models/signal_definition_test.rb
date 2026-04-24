# frozen_string_literal: true

require "test_helper"

# SignalDefinition — PRD §4.4 (was §4.2 in earlier PRD draft). System catalog,
# NOT tenant-scoped. Seeded from db/seeds/signal_definitions.yml.
class SignalDefinitionTest < ActiveSupport::TestCase
  def valid_attributes
    {
      code: "invoice.late_ratio_30d_test",
      category: "financial",
      source_system: "invoice_recon",
      direction: "higher_is_worse",
      value_type: "rate",
      default_weight: 0.15,
      description: "late payment ratio over a rolling 30-day window"
    }
  end

  test "valid with all required attributes" do
    sd = SignalDefinition.new(valid_attributes)
    assert sd.valid?, sd.errors.full_messages.to_sentence
  end

  test "code must be unique (system catalog)" do
    SignalDefinition.create!(valid_attributes)
    dup = SignalDefinition.new(valid_attributes)
    assert_not dup.valid?
    assert_includes dup.errors[:code], "has already been taken"
  end

  test "category rejects invalid values" do
    sd = SignalDefinition.new(valid_attributes.merge(category: "bogus"))
    assert_not sd.valid?
    assert_includes sd.errors[:category], "is not included in the list"
  end

  test "category accepts financial/contractual/integration/transactional" do
    %w[financial contractual integration transactional].each_with_index do |cat, i|
      sd = SignalDefinition.new(valid_attributes.merge(
        code: "test.cat.#{cat}",
        category: cat,
        # boolean value_type has no range constraints
        value_type: "boolean",
        default_weight: 0.0
      ))
      assert sd.valid?, "#{cat} should be accepted: #{sd.errors.full_messages}"
    end
  end

  test "source_system rejects invalid values" do
    sd = SignalDefinition.new(valid_attributes.merge(source_system: "sorcery"))
    assert_not sd.valid?
    assert_includes sd.errors[:source_system], "is not included in the list"
  end

  test "direction must be higher_is_worse or lower_is_worse" do
    sd = SignalDefinition.new(valid_attributes.merge(direction: "lower_is_better"))
    assert_not sd.valid?
    sd2 = SignalDefinition.new(valid_attributes.merge(direction: "higher_is_worse"))
    assert sd2.valid?
  end

  test "value_type accepts rate/count/duration_seconds/money_cents/boolean" do
    %w[rate count duration_seconds money_cents boolean].each_with_index do |vt, i|
      sd = SignalDefinition.new(valid_attributes.merge(
        code: "test.vt.#{vt}",
        value_type: vt
      ))
      assert sd.valid?, "#{vt} should be accepted: #{sd.errors.full_messages}"
    end
  end

  test "value_type rejects invalid values" do
    sd = SignalDefinition.new(valid_attributes.merge(value_type: "currency"))
    assert_not sd.valid?
  end

  test "default_weight must be between 0.0 and 1.0" do
    [-0.1, 1.01, 2.0].each do |bad|
      sd = SignalDefinition.new(valid_attributes.merge(
        code: "test.w.#{bad.to_s.gsub(/\W/, "_")}",
        default_weight: bad
      ))
      assert_not sd.valid?, "weight #{bad} should be invalid"
    end
    sd = SignalDefinition.new(valid_attributes.merge(
      code: "test.w.zero",
      default_weight: 0.0
    ))
    assert sd.valid?
    sd2 = SignalDefinition.new(valid_attributes.merge(
      code: "test.w.one",
      default_weight: 1.0
    ))
    assert sd2.valid?
  end

  test "is_active defaults to true" do
    sd = SignalDefinition.create!(valid_attributes)
    assert_equal true, sd.is_active
  end

  test "description is required" do
    sd = SignalDefinition.new(valid_attributes.merge(description: nil))
    assert_not sd.valid?
    assert_includes sd.errors[:description], "can't be blank"
  end

  test "not tenant-scoped (no tenant_id column)" do
    assert_not SignalDefinition.column_names.include?("tenant_id"),
      "signal_definitions must NOT have tenant_id per PRD §4.4 (system catalog)"
  end
end
