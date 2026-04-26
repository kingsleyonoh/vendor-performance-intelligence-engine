# frozen_string_literal: true

# signal_definitions — PRD §4.4. System catalog (NOT tenant-scoped).
# Seeded from db/seeds/signal_definitions.yml on every boot.
class CreateSignalDefinitions < ActiveRecord::Migration[8.0]
  def change
    create_table :signal_definitions, id: :uuid, default: "gen_random_uuid()" do |t|
      t.text :code, null: false
      t.text :category, null: false
      t.text :source_system, null: false
      t.text :direction, null: false
      t.text :value_type, null: false
      t.decimal :default_weight, precision: 5, scale: 4, null: false, default: 0.0
      t.text :description, null: false
      t.boolean :is_active, null: false, default: true
      t.timestamps
    end

    add_index :signal_definitions, :code, unique: true
    add_index :signal_definitions, :category
    add_index :signal_definitions, :source_system

    # DB-level enum guards matching PRD §4.4 CHECK constraints.
    execute <<~SQL
      ALTER TABLE signal_definitions
        ADD CONSTRAINT signal_definitions_category_chk
        CHECK (category IN ('financial','contractual','integration','transactional'))
    SQL
    execute <<~SQL
      ALTER TABLE signal_definitions
        ADD CONSTRAINT signal_definitions_direction_chk
        CHECK (direction IN ('higher_is_worse','lower_is_worse'))
    SQL
    execute <<~SQL
      ALTER TABLE signal_definitions
        ADD CONSTRAINT signal_definitions_value_type_chk
        CHECK (value_type IN ('rate','count','duration_seconds','money_cents','boolean'))
    SQL
    execute <<~SQL
      ALTER TABLE signal_definitions
        ADD CONSTRAINT signal_definitions_default_weight_chk
        CHECK (default_weight >= 0.0 AND default_weight <= 1.0)
    SQL
  end
end
