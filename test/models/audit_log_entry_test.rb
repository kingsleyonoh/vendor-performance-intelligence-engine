# frozen_string_literal: true

require "test_helper"

# AuditLogEntry — PRD §4.12. Insert-only audit trail. tenant_id has no FK
# (preserves rows after tenant deletion). Class method `.append!` is the
# only insert path; instance update! / destroy! raise.
class AuditLogEntryTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @other_tenant = tenants(:globex_inc_us)
  end

  # ---------------- Happy path ----------------
  test "append! inserts a row with all canonical fields" do
    entry = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "Tenant",
      actor_id: @tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "vendor-uuid-1",
      before_state: nil,
      after_state: { "canonical_name" => "Acme" },
      metadata: { "request_id" => "req-1", "ip" => "10.0.0.1" }
    )

    assert entry.persisted?
    assert_equal @tenant.id, entry.tenant_id
    assert_equal "Tenant", entry.actor_type
    assert_equal "vendors#create", entry.action
    assert_equal "Vendor", entry.entity_type
    assert_equal "vendor-uuid-1", entry.entity_id
    assert_equal({ "canonical_name" => "Acme" }, entry.after_state)
    assert_equal "req-1", entry.metadata["request_id"]
    assert_not_nil entry.occurred_at
  end

  # ---------------- Required fields ----------------
  test "rejects entry without actor_type" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AuditLogEntry.append!(
        tenant_id: @tenant.id,
        actor_type: nil,
        action: "vendors#create",
        entity_type: "Vendor",
        entity_id: "v-1"
      )
    end
  end

  test "rejects entry without action" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AuditLogEntry.append!(
        tenant_id: @tenant.id,
        actor_type: "Tenant",
        action: nil,
        entity_type: "Vendor",
        entity_id: "v-1"
      )
    end
  end

  test "rejects entry without entity_type" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AuditLogEntry.append!(
        tenant_id: @tenant.id,
        actor_type: "Tenant",
        action: "vendors#create",
        entity_type: nil,
        entity_id: "v-1"
      )
    end
  end

  # ---------------- Optional fields ----------------
  test "tenant_id can be NULL (cross-tenant or post-deletion rows)" do
    entry = AuditLogEntry.append!(
      tenant_id: nil,
      actor_type: "System",
      actor_id: "system.cron",
      action: "tenants#destroy",
      entity_type: "Tenant",
      entity_id: "deleted-tenant-uuid"
    )
    assert entry.persisted?
    assert_nil entry.tenant_id
  end

  test "entity_id can be NULL for aggregate actions" do
    entry = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "System",
      actor_id: "system.cron",
      action: "all_vendors_rescore_job#perform",
      entity_type: "VendorScore",
      entity_id: nil
    )
    assert entry.persisted?
    assert_nil entry.entity_id
  end

  test "metadata defaults to empty hash" do
    entry = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "Tenant",
      actor_id: @tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "v-1"
    )
    assert_equal({}, entry.metadata)
  end

  # ---------------- Insert-only at app layer ----------------
  test "save raises on already-persisted record (insert-only)" do
    entry = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "Tenant",
      actor_id: @tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "v-1"
    )

    entry.action = "tampered#now"
    assert_raises(AuditLogEntry::ImmutableRecord) do
      entry.save!
    end
  end

  test "update! raises ImmutableRecord" do
    entry = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "Tenant",
      actor_id: @tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "v-1"
    )

    assert_raises(AuditLogEntry::ImmutableRecord) do
      entry.update!(action: "tampered")
    end
  end

  test "destroy raises ImmutableRecord" do
    entry = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "Tenant",
      actor_id: @tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "v-1"
    )

    assert_raises(AuditLogEntry::ImmutableRecord) do
      entry.destroy!
    end
  end

  # ---------------- Tenant scoping ----------------
  test "scoping by tenant returns only that tenant's rows; cross-tenant query returns siblings" do
    own = AuditLogEntry.append!(
      tenant_id: @tenant.id,
      actor_type: "Tenant",
      actor_id: @tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "v-acme"
    )
    other = AuditLogEntry.append!(
      tenant_id: @other_tenant.id,
      actor_type: "Tenant",
      actor_id: @other_tenant.id,
      action: "vendors#create",
      entity_type: "Vendor",
      entity_id: "v-globex"
    )

    own_scope = AuditLogEntry.where(tenant_id: @tenant.id)
    assert_includes own_scope, own
    refute_includes own_scope, other

    cross_admin = AuditLogEntry.where(action: "vendors#create")
    assert_includes cross_admin, own
    assert_includes cross_admin, other
  end

  # ---------------- Ordering ----------------
  test "default scope orders by occurred_at desc" do
    older = AuditLogEntry.append!(
      tenant_id: @tenant.id, actor_type: "Tenant", actor_id: @tenant.id,
      action: "vendors#create", entity_type: "Vendor", entity_id: "v-old",
      occurred_at: 2.hours.ago
    )
    newer = AuditLogEntry.append!(
      tenant_id: @tenant.id, actor_type: "Tenant", actor_id: @tenant.id,
      action: "vendors#update", entity_type: "Vendor", entity_id: "v-new",
      occurred_at: 1.minute.ago
    )

    rows = AuditLogEntry.where(tenant_id: @tenant.id).recent.to_a
    assert_equal [newer, older].map(&:id) & rows.map(&:id), [newer, older].map(&:id)
    # newer must precede older
    assert rows.index(newer) < rows.index(older)
  end
end
