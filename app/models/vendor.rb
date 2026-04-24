# frozen_string_literal: true

# Vendor — PRD §4.3. Canonical tenant-scoped supplier row. Every
# `vendor_aliases`, `vendor_signals`, `vendor_scores`, `risk_alerts`,
# and `vendor_reports` row hangs off this one. Signals rely on the
# `(tenant_id, normalized_name)` index for the fuzzy-match resolver;
# keep `normalized_name` authoritative via the `before_validation`
# callback, never hand-populated.
class Vendor < ApplicationRecord
  STATUSES = %w[active watchlist terminated merged].freeze

  belongs_to :tenant
  has_many :vendor_aliases, dependent: :destroy

  before_validation :populate_normalized_name

  validates :canonical_name, presence: true, length: { maximum: 500 }
  validates :status, inclusion: { in: STATUSES }
  validates :country_code,
            allow_nil: true,
            format: { with: /\A[A-Z]{2}\z/, message: "must be ISO 3166-1 alpha-2" }
  validates :tax_id,
            uniqueness: { scope: :tenant_id },
            allow_nil: true
  validates :tenant, presence: true

  scope :active, -> { where(status: "active") }

  private

  # Keep normalized_name authoritative whenever canonical_name is set or
  # changed. Use the Ingestion::NameNormalizer pure function so every
  # consumer (resolver, controller, job) reads the same key.
  def populate_normalized_name
    return unless canonical_name.present?
    return unless canonical_name_changed? || normalized_name.blank?

    self.normalized_name = Ingestion::NameNormalizer.call(canonical_name)
  rescue ArgumentError
    # Canonical name was blank — validation will catch this; don't mask
    # the error by leaving normalized_name unset.
    self.normalized_name = nil
  end
end
