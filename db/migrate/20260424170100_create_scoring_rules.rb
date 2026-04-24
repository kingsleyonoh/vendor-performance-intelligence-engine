# frozen_string_literal: true

# scoring_rules — PRD §4.7. Per-tenant declarative configuration for the
# composite scorer: category weights, per-signal overrides, band thresholds,
# rolling window, and time-decay half-life. Exactly one row per tenant may
# have `is_active = true`; enforced by a partial unique index.
class CreateScoringRules < ActiveRecord::Migration[8.0]
  def change
    create_table :scoring_rules, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true

      t.text :name, null: false
      t.boolean :is_active, null: false, default: false
      t.jsonb :category_weights, null: false
      t.jsonb :signal_weight_overrides, null: false, default: {}
      t.jsonb :band_thresholds, null: false
      t.integer :window_days, null: false, default: 90
      t.integer :time_decay_half_life_days, null: false, default: 45
      t.timestamptz :activated_at

      t.timestamps
    end

    # Only ONE active scoring_rule per tenant. Partial unique index.
    add_index :scoring_rules,
              :tenant_id,
              unique: true,
              where: "is_active = true",
              name: "scoring_rules_tenant_active_uidx"

    # Audit history lookup.
    add_index :scoring_rules, [:tenant_id, :created_at]

    execute <<~SQL
      ALTER TABLE scoring_rules
        ADD CONSTRAINT scoring_rules_window_days_chk
        CHECK (window_days > 0)
    SQL

    execute <<~SQL
      ALTER TABLE scoring_rules
        ADD CONSTRAINT scoring_rules_half_life_chk
        CHECK (time_decay_half_life_days > 0)
    SQL
  end
end
