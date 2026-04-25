# frozen_string_literal: true

# VendorReport — PRD §4.9. One row per generated report. Five report
# types (vendor_scorecard, portfolio_risk, retender_candidates,
# trend_analysis), three output formats (pdf, csv, json).
#
# The `tenant_snapshot` and `render_context` jsonb columns are FROZEN
# at the queued → generating transition (PRD §5.6). Once populated they
# MUST NOT change — this is what makes audit reprints byte-identical
# 30 days after original generation, even if the source tenant/vendor
# rows have been mutated. This invariant is enforced at the model
# layer via `validate_snapshot_immutability`.
#
# Status state machine (PRD §4.9):
#
#   queued     → generating | failed
#   generating → ready | failed
#   ready      → expired
#   failed     → queued      # operator can re-queue a failed report
#   expired    → (terminal — operator can request a new report)
#
# Any other transition raises InvalidStatusTransition. The DB has a
# CHECK constraint backing the status enum.
class VendorReport < ApplicationRecord
  self.table_name = "vendor_reports"

  REPORT_TYPES   = %w[vendor_scorecard portfolio_risk retender_candidates trend_analysis].freeze
  STATUSES       = %w[queued generating ready failed expired].freeze
  OUTPUT_FORMATS = %w[pdf csv json].freeze

  TRANSITIONS = {
    "queued"     => %w[generating failed],
    "generating" => %w[ready failed],
    "ready"      => %w[expired],
    "failed"     => %w[queued],
    "expired"    => []
  }.freeze

  class InvalidStatusTransition < StandardError; end

  belongs_to :tenant
  belongs_to :vendor, optional: true
  belongs_to :requested_by_user, class_name: "User", optional: true

  validates :tenant, presence: true
  validates :report_type,   inclusion: { in: REPORT_TYPES }
  validates :status,        inclusion: { in: STATUSES }
  validates :output_format, inclusion: { in: OUTPUT_FORMATS }

  validate :validate_snapshot_immutability

  def transition_to!(new_status)
    new_status = new_status.to_s
    raise InvalidStatusTransition, "Unknown status: #{new_status.inspect}" unless STATUSES.include?(new_status)

    allowed = TRANSITIONS[status] || []
    unless allowed.include?(new_status) || new_status == status
      raise InvalidStatusTransition, "Cannot transition #{status} → #{new_status}"
    end

    self.status = new_status
    yield self if block_given?
    save!
    self
  end

  def to_s
    "#<VendorReport id=#{id} type=#{report_type} status=#{status}>"
  end

  private

  # Once tenant_snapshot or render_context is populated with a non-empty
  # hash, it MUST NOT be replaced. The first set (typically at the
  # queued → generating transition) freezes the values. Re-renders bind
  # to those frozen values forever.
  def validate_snapshot_immutability
    %i[tenant_snapshot render_context].each do |attr|
      next unless will_save_change_to_attribute?(attr)

      old_value, new_value = changes[attr.to_s]
      next if old_value.blank? || old_value == {} || old_value == "{}"
      next if old_value == new_value

      errors.add(attr, "is frozen once populated and cannot be replaced (PRD §5.6)")
    end
  end
end
