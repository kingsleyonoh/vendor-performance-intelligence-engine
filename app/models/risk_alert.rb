# frozen_string_literal: true

# RiskAlert — PRD §4.8. One row per band-crossing event per vendor per
# tenant. The `delivery_payload` column is captured ONCE at insertion
# via `Alerts::CapturePayload` (PRD §5.5) and is the only data the Hub
# dispatcher reads — no re-queries against tenants/vendors/vendor_scores.
#
# Status machine (PRD §4.8 + alert router design):
#
#   pending       → dispatching | suppressed
#   dispatching   → delivered | failed
#   delivered     → acknowledged
#   acknowledged  → resolved
#   failed        → pending           # retry path; failed is NOT terminal
#
# Any other transition raises InvalidStatusTransition. Status is
# enum-checked at the DB level too (CHECK constraint).
class RiskAlert < ApplicationRecord
  self.table_name = "risk_alerts"

  STATUSES = %w[pending dispatching delivered acknowledged resolved suppressed failed].freeze
  BANDS = %w[low medium high critical].freeze
  DIRECTIONS = %w[escalation improvement].freeze

  TRANSITIONS = {
    "pending"      => %w[dispatching suppressed],
    "dispatching"  => %w[delivered failed],
    "delivered"    => %w[acknowledged],
    "acknowledged" => %w[resolved],
    "resolved"     => [],
    "suppressed"   => [],
    "failed"       => %w[pending dispatching]
  }.freeze

  class InvalidStatusTransition < StandardError; end

  belongs_to :tenant
  belongs_to :vendor
  belongs_to :triggered_score, class_name: "VendorScore", foreign_key: :triggered_by_score

  validates :previous_band, inclusion: { in: BANDS }
  validates :new_band, inclusion: { in: BANDS }
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :previous_score, :new_score,
            presence: true,
            numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0 }
  validates :delivery_payload, presence: true
  validate :delivery_payload_must_be_a_hash

  scope :pending, -> { where(status: "pending") }
  scope :failed, -> { where(status: "failed") }
  scope :unacknowledged, -> { where(status: %w[pending dispatching delivered]) }

  # Move the alert to a new status, enforcing the transition matrix.
  # Caller passes a block to set associated columns (acknowledged_at,
  # last_error, etc.) atomically with the transition.
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

  # Mark as acknowledged with the operator identity recorded.
  def acknowledge!(by:)
    raise InvalidStatusTransition, "Cannot acknowledge an already-acknowledged alert" if acknowledged_at.present?

    transition_to!("acknowledged") do |alert|
      alert.acknowledged_at = Time.current
      alert.acknowledged_by = by.to_s
    end
  end

  private

  def delivery_payload_must_be_a_hash
    return if delivery_payload.is_a?(Hash)

    errors.add(:delivery_payload, "must be a Hash (got #{delivery_payload.class})")
  end
end
