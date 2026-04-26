require "test_helper"

# Scoring::AllVendorsRescoreJob — PRD §7, §13.3.
#
# Daily 02:00 UTC. Fans out to ScoreRecomputeJob per active vendor per
# tenant. Optional `tenant_id:` arg narrows fan-out to one tenant.
class Scoring::AllVendorsRescoreJobTest < ActiveJob::TestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @prev_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    AuditLogEntry.where(action: "scoring.bulk_rescore").delete_all
  end

  teardown do
    Current.tenant = nil
    ActiveJob::Base.queue_adapter = @prev_adapter
    AuditLogEntry.where(action: "scoring.bulk_rescore").delete_all
  end

  test "with no tenant_id: enqueues ScoreRecomputeJob for active vendors across all tenants" do
    acme_active   = Vendor.where(tenant_id: @acme.id, status: "active").count
    globex_active = Vendor.where(tenant_id: @globex.id, status: "active").count
    expected_total = acme_active + globex_active

    assert acme_active.positive?, "expected acme to have active vendor fixtures"
    assert globex_active.positive?, "expected globex to have active vendor fixtures"

    assert_enqueued_jobs(expected_total, only: ScoreRecomputeJob) do
      Scoring::AllVendorsRescoreJob.perform_now
    end
  end

  test "with tenant_id: only enqueues for that tenant's active vendors" do
    acme_active = Vendor.where(tenant_id: @acme.id, status: "active").count
    assert acme_active.positive?

    assert_enqueued_jobs(acme_active, only: ScoreRecomputeJob) do
      Scoring::AllVendorsRescoreJob.perform_now(tenant_id: @acme.id)
    end
  end

  test "skips terminated/merged vendors" do
    terminated = Vendor.create!(
      tenant: @acme, canonical_name: "Terminated Co", status: "terminated"
    )
    merged = Vendor.create!(
      tenant: @acme, canonical_name: "Merged Co", status: "merged",
      tax_id: "DE-MERGED-9999"
    )

    Scoring::AllVendorsRescoreJob.perform_now(tenant_id: @acme.id)

    enqueued_args = ActiveJob::Base.queue_adapter.enqueued_jobs
                       .select { |j| j["job_class"] == "ScoreRecomputeJob" }
                       .map { |j| j["arguments"] }
    enqueued_vendor_ids = enqueued_args.map(&:first)

    refute_includes enqueued_vendor_ids, terminated.id
    refute_includes enqueued_vendor_ids, merged.id
  end

  test "writes audit log per tenant" do
    Scoring::AllVendorsRescoreJob.perform_now

    audited = AuditLogEntry.where(action: "scoring.bulk_rescore").pluck(:tenant_id)
    assert_includes audited, @acme.id
    assert_includes audited, @globex.id
  end

  test "tolerates a tenant with zero active vendors (no enqueue, no audit)" do
    empty_tenant = Tenant.create!(
      name: "Empty",
      slug: "empty-#{SecureRandom.hex(3)}",
      api_key_hash: SecureRandom.hex(32),
      api_key_prefix: "vpi_empty_#{SecureRandom.hex(2)}"[0, 12],
      legal_name: "Empty Co",
      full_legal_name: "Empty Co Ltd",
      display_name: "Empty"
    )

    assert_enqueued_jobs(0, only: ScoreRecomputeJob) do
      Scoring::AllVendorsRescoreJob.perform_now(tenant_id: empty_tenant.id)
    end

    assert_equal 0, AuditLogEntry.where(action: "scoring.bulk_rescore", tenant_id: empty_tenant.id).count
  end
end
