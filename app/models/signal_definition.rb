# frozen_string_literal: true

# SignalDefinition — PRD §4.4. System catalog of signal types. NOT
# tenant-scoped. Seeded from `db/seeds/signal_definitions.yml` on every
# boot via `Rails.application.load_seed`.
class SignalDefinition < ApplicationRecord
  CATEGORIES = %w[financial contractual integration transactional].freeze
  SOURCE_SYSTEMS = %w[invoice_recon webhook_engine contract_engine recon_engine manual rag_platform].freeze
  DIRECTIONS = %w[higher_is_worse lower_is_worse].freeze
  VALUE_TYPES = %w[rate count duration_seconds money_cents boolean].freeze

  validates :code, presence: true, uniqueness: true
  validates :description, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :source_system, inclusion: { in: SOURCE_SYSTEMS }
  validates :direction, inclusion: { in: DIRECTIONS }
  validates :value_type, inclusion: { in: VALUE_TYPES }
  validates :default_weight,
            numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }
end
