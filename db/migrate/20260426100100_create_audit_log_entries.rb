# frozen_string_literal: true

# audit_log — PRD §4.12. INSERT-only mutation/action audit trail.
# `tenant_id` has NO foreign key — audit rows MUST survive tenant
# deletion so post-deletion forensic queries are possible. Insert-only
# at the application layer; we mirror the append-only-`vendor_signals`
# pattern: the model raises ImmutableRecord on update! / destroy!.
#
# Table is named `audit_log_entries` to match Rails plural convention
# and the AuditLogEntry model. Logical name (per PRD §4.12) is
# `audit_log`; we keep both names equivalent at the SQL view level if
# needed by external tooling, but the canonical table is
# `audit_log_entries`.
class CreateAuditLogEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_log_entries, id: :uuid, default: "gen_random_uuid()" do |t|
      # NO FK on tenant_id — preserves rows after tenant deletion.
      t.uuid :tenant_id, null: true

      t.text :actor_type, null: false
      t.text :actor_id,   null: true
      t.text :action,     null: false
      t.text :entity_type, null: false
      t.text :entity_id,   null: true

      t.jsonb :before_state, null: true
      t.jsonb :after_state,  null: true
      t.jsonb :metadata,     null: false, default: {}

      t.timestamptz :occurred_at, null: false, default: -> { "now()" }
      t.timestamps
    end

    add_index :audit_log_entries, [:tenant_id, :occurred_at],
              order: { occurred_at: :desc },
              name: "audit_log_tenant_occurred_idx"

    add_index :audit_log_entries, [:tenant_id, :entity_type, :entity_id, :occurred_at],
              order: { occurred_at: :desc },
              name: "audit_log_tenant_entity_idx"

    add_index :audit_log_entries, [:tenant_id, :action, :occurred_at],
              order: { occurred_at: :desc },
              name: "audit_log_tenant_action_idx"

    # Cross-tenant admin feed.
    add_index :audit_log_entries, [:occurred_at],
              order: { occurred_at: :desc },
              name: "audit_log_occurred_idx"
  end
end
