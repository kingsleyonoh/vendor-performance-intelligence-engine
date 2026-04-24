# frozen_string_literal: true

require "test_helper"

# VendorSignal — PRD §4.5. Append-only, partitioned by recorded_at.
# Every test loads ≥2 tenants (Multi-Tenant Fixtures Mandatory) to catch
# cross-tenant leakage at RED phase.
class VendorSignalTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Supplier GmbH")
    @globex_vendor = Vendor.create!(tenant: @globex, canonical_name: "Globex Supplier Inc")
  end

  def valid_attrs(overrides = {})
    {
      tenant: @acme,
      vendor: @acme_vendor,
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "evt-#{SecureRandom.hex(4)}",
      value_numeric: 0.15,
      window_start: 30.days.ago,
      window_end: Time.now.utc,
      recorded_at: Time.now.utc,
      status: "normalized"
    }.merge(overrides)
  end

  test "valid with minimal required attributes" do
    s = VendorSignal.new(valid_attrs)
    assert s.valid?, s.errors.full_messages.to_sentence
    assert s.save
  end

  test "tenant is required" do
    s = VendorSignal.new(valid_attrs(tenant: nil))
    assert_not s.valid?
  end

  test "vendor is required" do
    s = VendorSignal.new(valid_attrs(vendor: nil))
    assert_not s.valid?
  end

  test "signal_code is required" do
    s = VendorSignal.new(valid_attrs(signal_code: nil))
    assert_not s.valid?
  end

  test "source_system must be in enum" do
    s = VendorSignal.new(valid_attrs(source_system: "bogus"))
    assert_not s.valid?
  end

  test "status must be in enum" do
    s = VendorSignal.new(valid_attrs(status: "bogus"))
    assert_not s.valid?
  end

  test "status defaults to normalized" do
    s = VendorSignal.create!(valid_attrs.except(:status))
    assert_equal "normalized", s.status
  end

  test "dedup enforced on (tenant_id, source_system, source_event_id, recorded_at)" do
    # Partitioned tables in Postgres REQUIRE the partition key in any
    # unique index, so our dedup tuple includes recorded_at. The common
    # "same event_id same moment" collision does raise — identical
    # recorded_at + event_id is caught at the DB.
    recorded = Time.now.utc
    VendorSignal.create!(valid_attrs(source_event_id: "dedup-1", recorded_at: recorded))
    dup = VendorSignal.new(valid_attrs(source_event_id: "dedup-1",
                                       recorded_at: recorded,
                                       vendor: @acme_vendor,
                                       value_numeric: 0.99))
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "dedup is tenant-scoped: same source_event_id + recorded_at OK on different tenant" do
    recorded = Time.now.utc
    VendorSignal.create!(valid_attrs(source_event_id: "same-id", recorded_at: recorded))
    other = VendorSignal.new(valid_attrs(tenant: @globex,
                                         vendor: @globex_vendor,
                                         source_event_id: "same-id",
                                         recorded_at: recorded))
    assert other.save
  end

  test "append-only: raw SQL UPDATE of value_numeric raises at DB layer (trigger)" do
    s = VendorSignal.create!(valid_attrs)
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.connection.execute(
        "UPDATE vendor_signals SET value_numeric = 0.99 WHERE id = '#{s.id}'"
      )
    end
  end

  test "append-only: raw SQL DELETE raises at DB layer (trigger)" do
    s = VendorSignal.create!(valid_attrs)
    assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.connection.execute(
        "DELETE FROM vendor_signals WHERE id = '#{s.id}'"
      )
    end
  end

  test "append-only: model #destroy raises" do
    s = VendorSignal.create!(valid_attrs)
    assert_raises(VendorSignal::AppendOnlyViolation) { s.destroy }
  end

  test "append-only: model #update raises on non-status change" do
    s = VendorSignal.create!(valid_attrs)
    assert_raises(VendorSignal::AppendOnlyViolation) do
      s.update(value_numeric: 0.9)
    end
  end

  test "legal status transition: normalized -> scored allowed" do
    s = VendorSignal.create!(valid_attrs(status: "normalized"))
    assert s.update(status: "scored")
    assert_equal "scored", s.reload.status
  end

  test "legal status transition: normalized -> superseded allowed" do
    s = VendorSignal.create!(valid_attrs(status: "normalized"))
    assert s.update(status: "superseded")
  end

  test "legal status transition: raw -> normalized allowed" do
    s = VendorSignal.create!(valid_attrs(status: "raw"))
    assert s.update(status: "normalized")
  end

  test "illegal status transition: normalized -> raw rejected" do
    s = VendorSignal.create!(valid_attrs(status: "normalized"))
    assert_raises(VendorSignal::AppendOnlyViolation) do
      s.update(status: "raw")
    end
  end

  test "illegal status transition: scored -> normalized rejected" do
    s = VendorSignal.create!(valid_attrs(status: "normalized"))
    s.update!(status: "scored")
    assert_raises(VendorSignal::AppendOnlyViolation) do
      s.update(status: "normalized")
    end
  end

  test "value_numeric XOR value_boolean required (at least one when not rejected)" do
    # Both missing on a normalized row → CHECK constraint fails
    s = VendorSignal.new(valid_attrs(value_numeric: nil, value_boolean: nil, status: "normalized"))
    assert_raises(ActiveRecord::StatementInvalid) { s.save!(validate: false) }
  end

  test "value_boolean accepted for boolean signals" do
    s = VendorSignal.new(valid_attrs(signal_code: "contract.renewal_at_risk",
                                     source_system: "contract_engine",
                                     value_numeric: nil,
                                     value_boolean: true))
    assert s.save
  end

  test "append! class method is idempotent on dedup key" do
    attrs = valid_attrs(source_event_id: "idempotent-1")
    s1 = VendorSignal.append!(attrs)
    s2 = VendorSignal.append!(attrs)
    assert_equal s1.id, s2.id
  end

  test "tenant-isolation: acme's signal not visible to globex scope" do
    s = VendorSignal.create!(valid_attrs)
    assert_nil VendorSignal.where(tenant_id: @globex.id).find_by(id: s.id)
  end
end
