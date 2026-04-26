# frozen_string_literal: true

# vendor_reports — PRD §4.9. Generated report rows. The `tenant_snapshot`
# and `render_context` jsonb columns are FROZEN at the queued → generating
# transition (PRD §5.6). Re-renders (PDF re-downloads, audit reprints)
# bind to those frozen columns and NEVER re-query live tenants/vendors.
# This is what makes audit reprints byte-identical 30 days later
# (PRD §15 #13).
#
# `vendor_id` is nullable — portfolio_risk and trend_analysis report
# types are tenant-scoped, not vendor-scoped.
class CreateVendorReports < ActiveRecord::Migration[8.0]
  REPORT_TYPES   = %w[vendor_scorecard portfolio_risk retender_candidates trend_analysis].freeze
  STATUSES       = %w[queued generating ready failed expired].freeze
  OUTPUT_FORMATS = %w[pdf csv json].freeze

  def change
    create_table :vendor_reports, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :vendor, type: :uuid, null: true, foreign_key: true

      t.text :report_type,   null: false
      t.text :status,        null: false, default: "queued"
      t.text :output_format, null: false

      t.jsonb :parameters,      null: false, default: {}
      t.jsonb :tenant_snapshot, null: false, default: {}
      t.jsonb :render_context,  null: false, default: {}

      t.text :storage_path
      t.text :inline_payload

      # Users still use bigint ids (Rails 8 default); reports may be
      # operator-requested or system-requested (nullable).
      t.references :requested_by_user, null: true,
                                       foreign_key: { to_table: :users }

      t.timestamptz :generated_at
      t.timestamptz :expires_at
      t.text        :error_summary

      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE vendor_reports
        ADD CONSTRAINT vendor_reports_report_type_chk
        CHECK (report_type IN ('#{REPORT_TYPES.join("','")}'))
    SQL

    execute <<~SQL
      ALTER TABLE vendor_reports
        ADD CONSTRAINT vendor_reports_status_chk
        CHECK (status IN ('#{STATUSES.join("','")}'))
    SQL

    execute <<~SQL
      ALTER TABLE vendor_reports
        ADD CONSTRAINT vendor_reports_output_format_chk
        CHECK (output_format IN ('#{OUTPUT_FORMATS.join("','")}'))
    SQL

    # Operational indexes (PRD §4.9).
    add_index :vendor_reports, [:tenant_id, :created_at],
              order: { created_at: :desc },
              name: "vendor_reports_tenant_created_idx"

    add_index :vendor_reports, [:tenant_id, :status],
              name: "vendor_reports_tenant_status_idx"

    add_index :vendor_reports, [:tenant_id, :vendor_id, :report_type, :created_at],
              order: { created_at: :desc },
              name: "vendor_reports_tenant_vendor_type_idx"

    # Partial index for ExpiredReportReaperJob — only ready rows have an
    # expires_at worth scanning.
    add_index :vendor_reports, [:tenant_id, :expires_at],
              where: "status = 'ready'",
              name: "vendor_reports_tenant_expires_ready_idx"
  end
end
