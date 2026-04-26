# frozen_string_literal: true

require "test_helper"

# Ingestion::SignalValidator — PRD §5.3. dry-validation contract for
# incoming signal payloads. Returns a Dry::Validation::Result; success?
# wraps #to_h, failure emits the reject matrix:
#   UNKNOWN_SIGNAL_CODE | VALUE_OUT_OF_RANGE | FUTURE_TIMESTAMP |
#   STALE_TIMESTAMP | WINDOW_INVERTED | MISSING_VENDOR_REF
#
# Tests exercise each matrix entry + the happy path.
class SignalValidatorTest < ActiveSupport::TestCase
  def setup
    ensure_signal_catalog_seeded
  end

  def valid_payload(overrides = {})
    {
      vendor_ref: { source_system_ref: "acme-vendor-123" },
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "evt-#{SecureRandom.hex(4)}",
      value_numeric: 0.25,
      recorded_at: (Time.now.utc - 1.day).iso8601
    }.merge(overrides)
  end

  # ---------------- happy path ----------------

  test "happy path: valid payload returns success" do
    result = Ingestion::SignalValidator.call(valid_payload)
    assert result.success?, "expected success but got errors: #{result.errors.to_h}"
  end

  test "happy path: payload with all optional fields" do
    result = Ingestion::SignalValidator.call(valid_payload(
      window_start: (Time.now.utc - 30.days).iso8601,
      window_end: (Time.now.utc - 1.hour).iso8601,
      context: { source_invoice_id: "inv-99" },
      vendor_ref: { tax_id: "DE123456789", normalized_name: "acme gmbh",
                    source_system_ref: "upstream-id-1" }
    ))
    assert result.success?, result.errors.to_h.inspect
  end

  test "happy path: boolean signal with value_boolean" do
    result = Ingestion::SignalValidator.call(valid_payload(
      signal_code: "contract.renewal_at_risk",
      source_system: "contract_engine",
      value_numeric: nil,
      value_boolean: true
    ))
    assert result.success?, result.errors.to_h.inspect
  end

  # ---------------- MISSING_VENDOR_REF ----------------

  test "fails when vendor_ref is missing entirely" do
    payload = valid_payload.except(:vendor_ref)
    result = Ingestion::SignalValidator.call(payload)
    refute result.success?
    assert_includes result.errors.to_h.keys.map(&:to_s), "vendor_ref"
  end

  test "fails when vendor_ref is present but empty" do
    result = Ingestion::SignalValidator.call(valid_payload(vendor_ref: {}))
    refute result.success?
    assert reason_for(result).include?("MISSING_VENDOR_REF")
  end

  # ---------------- UNKNOWN_SIGNAL_CODE ----------------

  test "fails when signal_code is not in signal_definitions" do
    result = Ingestion::SignalValidator.call(valid_payload(signal_code: "bogus.unknown_code"))
    refute result.success?
    assert reason_for(result).include?("UNKNOWN_SIGNAL_CODE")
  end

  test "fails when signal_code is missing" do
    result = Ingestion::SignalValidator.call(valid_payload.except(:signal_code))
    refute result.success?
  end

  # ---------------- FUTURE_TIMESTAMP ----------------

  test "fails when recorded_at is > 1 hour in the future" do
    result = Ingestion::SignalValidator.call(valid_payload(
      recorded_at: (Time.now.utc + 2.hours).iso8601
    ))
    refute result.success?
    assert reason_for(result).include?("FUTURE_TIMESTAMP")
  end

  test "accepts recorded_at within 1-hour clock-skew window" do
    result = Ingestion::SignalValidator.call(valid_payload(
      recorded_at: (Time.now.utc + 30.minutes).iso8601
    ))
    assert result.success?, result.errors.to_h.inspect
  end

  # ---------------- STALE_TIMESTAMP ----------------

  test "fails when recorded_at is older than MAX_SIGNAL_BACKFILL_DAYS" do
    result = Ingestion::SignalValidator.call(valid_payload(
      recorded_at: (Time.now.utc - 400.days).iso8601
    ))
    refute result.success?
    assert reason_for(result).include?("STALE_TIMESTAMP")
  end

  # ---------------- WINDOW_INVERTED ----------------

  test "fails when window_end is before window_start" do
    result = Ingestion::SignalValidator.call(valid_payload(
      window_start: (Time.now.utc - 1.day).iso8601,
      window_end: (Time.now.utc - 10.days).iso8601
    ))
    refute result.success?
    assert reason_for(result).include?("WINDOW_INVERTED")
  end

  # ---------------- VALUE_OUT_OF_RANGE (rate > 1.0) ----------------

  test "fails when rate signal has value_numeric > 1.0" do
    # invoice.late_ratio_30d is value_type=rate
    result = Ingestion::SignalValidator.call(valid_payload(value_numeric: 1.5))
    refute result.success?
    assert reason_for(result).include?("VALUE_OUT_OF_RANGE")
  end

  test "fails when rate signal has value_numeric < 0" do
    result = Ingestion::SignalValidator.call(valid_payload(value_numeric: -0.1))
    refute result.success?
    assert reason_for(result).include?("VALUE_OUT_OF_RANGE")
  end

  # ---------------- value/type mismatch ----------------

  test "fails when numeric signal is missing value_numeric" do
    result = Ingestion::SignalValidator.call(valid_payload(value_numeric: nil))
    refute result.success?
  end

  test "fails when boolean signal is missing value_boolean" do
    result = Ingestion::SignalValidator.call(valid_payload(
      signal_code: "contract.renewal_at_risk",
      source_system: "contract_engine",
      value_numeric: nil,
      value_boolean: nil
    ))
    refute result.success?
  end

  # ---------------- source_system ----------------

  test "fails when source_system is not in the enum" do
    result = Ingestion::SignalValidator.call(valid_payload(source_system: "bogus"))
    refute result.success?
  end

  # ---------------- source_event_id ----------------

  test "fails when source_event_id is missing" do
    result = Ingestion::SignalValidator.call(valid_payload.except(:source_event_id))
    refute result.success?
  end

  # ---------------- reason emitter ----------------

  test "rejection_reason_for returns canonical reason from failure messages" do
    result = Ingestion::SignalValidator.call(valid_payload(signal_code: "nope.unknown"))
    refute result.success?
    reason = Ingestion::SignalValidator.rejection_reason_for(result)
    assert_equal "UNKNOWN_SIGNAL_CODE", reason
  end

  private

  def ensure_signal_catalog_seeded
    return if SignalDefinition.exists?

    yml = YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml"))
    yml.each { |row| SignalDefinition.create!(row) }
  end

  def reason_for(result)
    # Concatenate all error messages — the reason sentinel appears in
    # at least one message string.
    result.errors.to_h.to_s
  end
end
