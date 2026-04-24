# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_04_24_150300) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "tenant_id", null: false
    t.index ["tenant_id"], name: "index_sessions_on_tenant_id"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "signal_definitions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "code", null: false
    t.text "category", null: false
    t.text "source_system", null: false
    t.text "direction", null: false
    t.text "value_type", null: false
    t.decimal "default_weight", precision: 5, scale: 4, default: "0.0", null: false
    t.text "description", null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_signal_definitions_on_category"
    t.index ["code"], name: "index_signal_definitions_on_code", unique: true
    t.index ["source_system"], name: "index_signal_definitions_on_source_system"
    t.check_constraint "category = ANY (ARRAY['financial'::text, 'contractual'::text, 'integration'::text, 'transactional'::text])", name: "signal_definitions_category_chk"
    t.check_constraint "default_weight >= 0.0 AND default_weight <= 1.0", name: "signal_definitions_default_weight_chk"
    t.check_constraint "direction = ANY (ARRAY['higher_is_worse'::text, 'lower_is_worse'::text])", name: "signal_definitions_direction_chk"
    t.check_constraint "value_type = ANY (ARRAY['rate'::text, 'count'::text, 'duration_seconds'::text, 'money_cents'::text, 'boolean'::text])", name: "signal_definitions_value_type_chk"
  end

  create_table "tenants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "name", null: false
    t.text "slug", null: false
    t.text "api_key_hash", null: false
    t.text "api_key_prefix", null: false
    t.jsonb "settings", default: {}, null: false
    t.text "legal_name", default: "", null: false
    t.text "full_legal_name", default: "", null: false
    t.text "display_name", default: "", null: false
    t.jsonb "address", default: {}, null: false
    t.jsonb "registration", default: {}, null: false
    t.jsonb "contact", default: {}, null: false
    t.text "wordmark_url"
    t.text "brand_primary_hex", default: "#0D0D0F", null: false
    t.text "brand_accent_hex", default: "#3B82F6", null: false
    t.text "locale", default: "en-US", null: false
    t.text "timezone", default: "UTC", null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_key_hash"], name: "index_tenants_on_api_key_hash", unique: true
    t.index ["api_key_prefix"], name: "index_tenants_on_api_key_prefix", unique: true
    t.index ["is_active"], name: "index_tenants_on_is_active"
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "tenant_id", null: false
    t.index ["tenant_id", "email_address"], name: "index_users_on_tenant_id_and_email_address", unique: true
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "sessions", "tenants"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "tenants"
end
