# frozen_string_literal: true

# VendorAlias — PRD §4.4. Pins an upstream (source_system, source_ref)
# tuple to a canonical `Vendor` row. Confidence ladder (PRD §5.2):
#
#   - 1.00: exact tax_id match (auto-confirmed)
#   - 0.85: exact normalized_name match (pending operator confirmation)
#   - 0.70: Levenshtein <= AUTO_MATCH_FUZZY_THRESHOLD (pending)
#   - 1.00: freshly-created vendor (trivially confirmed)
#
# Operators confirm pending rows via the Phase 1 alias review UI.
class VendorAlias < ApplicationRecord
  SOURCE_SYSTEMS = %w[
    invoice_recon
    webhook_engine
    contract_engine
    recon_engine
    rag_platform
    manual
  ].freeze

  belongs_to :tenant
  belongs_to :vendor

  validates :source_system, inclusion: { in: SOURCE_SYSTEMS }
  validates :source_ref, presence: true
  validates :source_ref, uniqueness: { scope: [:tenant_id, :source_system] }
  validates :confidence,
            numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }

  scope :pending, -> { where(is_confirmed: false) }
  scope :confirmed, -> { where(is_confirmed: true) }
end
