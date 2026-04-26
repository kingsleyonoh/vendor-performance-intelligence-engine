# frozen_string_literal: true

# vendor_aliases — PRD §4.4. Reconciles `(source_system, source_ref)` tuples
# from upstream ecosystem services to the canonical `vendors` row.
# Auto-match priority: exact tax_id (1.00) -> exact normalized_name (0.85)
# -> Levenshtein <= 2 (0.70) -> new vendor (1.00). Operator confirms any
# alias with confidence < 1.00 via the pending-review UI.
class CreateVendorAliases < ActiveRecord::Migration[8.0]
  def change
    create_table :vendor_aliases, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :vendor, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      t.text :source_system, null: false
      t.text :source_ref, null: false             # upstream's internal vendor identifier
      t.text :alias_text                          # raw name as seen in source payload (audit)
      t.decimal :confidence, precision: 4, scale: 3, null: false
      t.boolean :is_confirmed, null: false, default: false

      t.timestamps
    end

    # One alias per (tenant, source_system, source_ref) — idempotency key.
    add_index :vendor_aliases,
              [:tenant_id, :source_system, :source_ref],
              unique: true,
              name: "index_vendor_aliases_on_tenant_system_ref"

    # Fan-out: all aliases for a vendor within a tenant.
    add_index :vendor_aliases, [:tenant_id, :vendor_id]

    # Pending-review queue lookup (partial index — only unconfirmed rows).
    add_index :vendor_aliases,
              [:tenant_id, :is_confirmed],
              where: "is_confirmed = false",
              name: "index_vendor_aliases_pending"

    # DB-level enum guard on source_system.
    execute <<~SQL
      ALTER TABLE vendor_aliases
        ADD CONSTRAINT vendor_aliases_source_system_chk
        CHECK (source_system IN ('invoice_recon','webhook_engine','contract_engine','recon_engine','rag_platform','manual'))
    SQL

    # Confidence in [0, 1].
    execute <<~SQL
      ALTER TABLE vendor_aliases
        ADD CONSTRAINT vendor_aliases_confidence_chk
        CHECK (confidence >= 0.0 AND confidence <= 1.0)
    SQL
  end
end
