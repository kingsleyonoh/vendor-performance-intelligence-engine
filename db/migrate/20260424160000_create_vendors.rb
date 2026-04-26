# frozen_string_literal: true

# vendors — PRD §4.3. Canonical vendor directory per tenant. Every query
# pattern is backed by a composite index on `(tenant_id, …)` per PRD §2
# Architecture Principle 1.
class CreateVendors < ActiveRecord::Migration[8.0]
  def change
    create_table :vendors, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true

      t.text :canonical_name, null: false          # operator-facing display name
      t.text :normalized_name, null: false         # NameNormalizer output — fuzzy-match key
      t.text :tax_id                               # nullable; country-specific VAT/EIN
      t.text :country_code                         # ISO 3166-1 alpha-2; nullable
      t.text :category                             # operator-labeled segment; nullable
      t.bigint :annual_spend_cents                 # most recent annual spend in cents; nullable
      t.text :currency                             # ISO 4217; nullable
      t.text :status, null: false, default: "active"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # Composite indexes matching the 4 primary query patterns (PRD §2).
    add_index :vendors, [:tenant_id, :status]
    add_index :vendors, [:tenant_id, :normalized_name]
    add_index :vendors, [:tenant_id, :tax_id],
              unique: true,
              where: "tax_id IS NOT NULL",
              name: "index_vendors_on_tenant_id_and_tax_id_where_present"
    add_index :vendors, [:tenant_id, :category],
              where: "category IS NOT NULL",
              name: "index_vendors_on_tenant_id_and_category_where_present"

    # DB-level enum guard on status per PRD §4.3.
    execute <<~SQL
      ALTER TABLE vendors
        ADD CONSTRAINT vendors_status_chk
        CHECK (status IN ('active','watchlist','terminated','merged'))
    SQL

    # country_code is ISO 3166-1 alpha-2 when present (2 uppercase letters).
    execute <<~SQL
      ALTER TABLE vendors
        ADD CONSTRAINT vendors_country_code_chk
        CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$')
    SQL
  end
end
