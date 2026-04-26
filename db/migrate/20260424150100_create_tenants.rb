# frozen_string_literal: true

# tenants table — PRD §4.1 + §4.T. Identity columns (legal_name through
# timezone) are bound by every template surface (PDF, email, UI, Hub
# payload). Any column missing here breaks strict-undefined rendering.
class CreateTenants < ActiveRecord::Migration[8.0]
  def change
    create_table :tenants, id: :uuid, default: "gen_random_uuid()" do |t|
      t.text :name, null: false                        # operational name
      t.text :slug, null: false                        # lowercase, hyphens
      t.text :api_key_hash, null: false                # SHA-256 hex
      t.text :api_key_prefix, null: false              # first 12 chars of raw key
      t.jsonb :settings, null: false, default: {}

      # §4.T identity columns (bound by templates)
      t.text :legal_name, null: false, default: ""
      t.text :full_legal_name, null: false, default: ""
      t.text :display_name, null: false, default: ""
      t.jsonb :address, null: false, default: {}
      t.jsonb :registration, null: false, default: {}
      t.jsonb :contact, null: false, default: {}
      t.text :wordmark_url
      t.text :brand_primary_hex, null: false, default: "#0D0D0F"
      t.text :brand_accent_hex, null: false, default: "#3B82F6"
      t.text :locale, null: false, default: "en-US"
      t.text :timezone, null: false, default: "UTC"

      t.boolean :is_active, null: false, default: true
      t.timestamps
    end

    add_index :tenants, :slug, unique: true
    add_index :tenants, :api_key_hash, unique: true
    add_index :tenants, :api_key_prefix, unique: true
    add_index :tenants, :is_active
  end
end
