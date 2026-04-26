# frozen_string_literal: true

# risk_alerts — PRD §4.8. Band-crossing alert ledger. Inserted by the
# alert router when a vendor's score band changes; dispatched by
# HubDispatchJob (Phase 2 batch 016+).
#
# `delivery_payload` is FROZEN at insertion (PRD §5.5 + invariant). The
# Hub dispatcher reads ONLY from this column and NEVER re-queries
# tenants/vendors/vendor_scores — that is what makes alert history
# legally defensible (a tenant rename mid-retry must not change the
# emitted Hub event).
class CreateRiskAlerts < ActiveRecord::Migration[8.0]
  def change
    create_table :risk_alerts, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :vendor, type: :uuid, null: false, foreign_key: true

      t.text :previous_band, null: false
      t.text :new_band, null: false
      t.decimal :previous_score, precision: 6, scale: 3, null: false
      t.decimal :new_score, precision: 6, scale: 3, null: false
      t.text :direction, null: false
      t.uuid :triggered_by_score, null: false

      t.text :status, null: false, default: "pending"
      t.jsonb :delivery_payload, null: false, default: {}

      t.text :hub_event_id
      t.text :workflow_execution_id

      t.integer :dispatch_attempts, null: false, default: 0
      t.timestamptz :last_attempt_at
      t.text :last_error
      t.timestamptz :acknowledged_at
      t.text :acknowledged_by
      t.timestamptz :resolved_at
      t.timestamptz :suppressed_until

      t.timestamps
    end

    # FK is to vendor_scores — but vendor_scores has a composite-only
    # unique constraint on id (no PK on id alone). PRD §4.8 calls this
    # an "FK"; Rails-level association is via belongs_to and the
    # vendor_scores.id column. We add the constraint via raw SQL since
    # the index references a single-column id implicitly created by
    # the create_table.
    execute <<~SQL
      ALTER TABLE risk_alerts
        ADD CONSTRAINT risk_alerts_triggered_by_score_fk
        FOREIGN KEY (triggered_by_score)
        REFERENCES vendor_scores(id)
        ON DELETE RESTRICT
    SQL

    # Status enum (PRD §4.8 transitions).
    execute <<~SQL
      ALTER TABLE risk_alerts
        ADD CONSTRAINT risk_alerts_status_chk
        CHECK (status IN ('pending','dispatching','delivered','acknowledged','resolved','suppressed','failed'))
    SQL

    # Band enums (PRD §4.7).
    execute <<~SQL
      ALTER TABLE risk_alerts
        ADD CONSTRAINT risk_alerts_previous_band_chk
        CHECK (previous_band IN ('low','medium','high','critical'))
    SQL
    execute <<~SQL
      ALTER TABLE risk_alerts
        ADD CONSTRAINT risk_alerts_new_band_chk
        CHECK (new_band IN ('low','medium','high','critical'))
    SQL

    # direction (PRD §4.8).
    execute <<~SQL
      ALTER TABLE risk_alerts
        ADD CONSTRAINT risk_alerts_direction_chk
        CHECK (direction IN ('escalation','improvement'))
    SQL

    # Indexes (PRD §4.8 explicit, plus operational queries).
    add_index :risk_alerts, [:tenant_id, :status, :created_at],
              order: { created_at: :desc },
              name: "risk_alerts_tenant_status_idx"
    add_index :risk_alerts, [:tenant_id, :vendor_id, :created_at],
              order: { created_at: :desc },
              name: "risk_alerts_tenant_vendor_idx"
    add_index :risk_alerts, [:tenant_id, :created_at],
              order: { created_at: :desc },
              name: "risk_alerts_tenant_created_idx"
    add_index :risk_alerts, [:tenant_id, :new_band, :created_at],
              order: { created_at: :desc },
              name: "risk_alerts_tenant_new_band_idx"

    # Idempotency: at most one alert per (tenant, vendor, score) — a
    # given score insertion fires at most one alert. This guards the
    # Phase 2 alert router against double-firing on retries.
    add_index :risk_alerts, [:tenant_id, :vendor_id, :triggered_by_score],
              unique: true,
              name: "risk_alerts_idempotency_uidx"
  end
end
