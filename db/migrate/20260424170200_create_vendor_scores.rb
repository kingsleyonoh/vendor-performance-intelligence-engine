# frozen_string_literal: true

# vendor_scores — PRD §4.6. Composite score snapshots per vendor per
# tenant. Every recompute INSERTs a new row; the latest row per
# (tenant_id, vendor_id) is the "current" score. `top_contributors`
# captures the top 5 signals by absolute contribution — invariant 4
# (explainability) depends on this column being populated.
class CreateVendorScores < ActiveRecord::Migration[8.0]
  def change
    create_table :vendor_scores, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :vendor, type: :uuid, null: false, foreign_key: true
      t.references :scoring_rules, type: :uuid, null: false, foreign_key: { to_table: :scoring_rules }

      t.decimal :composite_score, precision: 6, scale: 3, null: false
      t.text :band, null: false
      t.text :trend, null: false
      t.jsonb :category_scores, null: false
      t.jsonb :top_contributors, null: false, default: []
      t.integer :window_days, null: false
      t.integer :signals_considered_count, null: false, default: 0
      t.timestamptz :computed_at, null: false, default: -> { "NOW()" }

      t.timestamps
    end

    add_index :vendor_scores, [:tenant_id, :vendor_id, :computed_at], order: { computed_at: :desc }
    add_index :vendor_scores, [:tenant_id, :band, :computed_at], order: { computed_at: :desc }
    add_index :vendor_scores, [:tenant_id, :computed_at], order: { computed_at: :desc }

    execute <<~SQL
      ALTER TABLE vendor_scores
        ADD CONSTRAINT vendor_scores_band_chk
        CHECK (band IN ('low','medium','high','critical'))
    SQL

    execute <<~SQL
      ALTER TABLE vendor_scores
        ADD CONSTRAINT vendor_scores_trend_chk
        CHECK (trend IN ('improving','stable','degrading','new'))
    SQL

    execute <<~SQL
      ALTER TABLE vendor_scores
        ADD CONSTRAINT vendor_scores_composite_range_chk
        CHECK (composite_score >= 0.0 AND composite_score <= 100.0)
    SQL
  end
end
