# frozen_string_literal: true

# VendorSignal — PRD §4.5. Append-only time-series; the source of truth for
# all scoring. Partitioned by month on `recorded_at` via native Postgres
# declarative partitioning (see 20260424170000_create_vendor_signals.rb).
#
# Invariant 3 (PRD §2): signals are facts. This class enforces the
# append-only contract at the model layer; a DB trigger provides a second
# line of defense. Corrections are done by INSERTing a new row that
# references the old via `supersedes_id`, and transitioning the old row
# from `normalized → superseded` (the only mutation allowed).
class VendorSignal < ApplicationRecord
  # Raised when any caller attempts to mutate a row in a way other than a
  # legal status transition (e.g. UPDATE of value_numeric, DELETE).
  class AppendOnlyViolation < StandardError; end

  SOURCE_SYSTEMS = %w[invoice_recon webhook_engine contract_engine recon_engine rag_platform manual].freeze
  STATUSES = %w[raw normalized scored rejected superseded].freeze

  # Legal status transitions. Every other move raises.
  STATUS_TRANSITIONS = {
    "raw" => %w[normalized rejected],
    "normalized" => %w[scored superseded]
  }.freeze

  # The DB primary key is a composite (id, recorded_at) because Postgres
  # requires the partition key in any PK on a partitioned table. Rails
  # surfaces that as an array on `.id` which breaks equality assertions
  # like `assert_equal s1.id, s2.id`. Expose `id` as the uuid alone —
  # operations that truly need the PK tuple can use `[self.id, self.recorded_at]`
  # directly.
  self.primary_key = :id

  belongs_to :tenant
  belongs_to :vendor

  validates :tenant, presence: true
  validates :vendor, presence: true
  validates :signal_code, presence: true, length: { maximum: 200 }
  validates :source_system, presence: true, inclusion: { in: SOURCE_SYSTEMS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :recorded_at, presence: true

  before_create :default_status

  # -------------------------------------------------------------------
  # Append-only enforcement at the model layer. The DB trigger raises
  # anyway, but catching at the model layer gives callers a clean Ruby
  # exception (AppendOnlyViolation) instead of a generic StatementInvalid.
  # -------------------------------------------------------------------
  def destroy
    raise AppendOnlyViolation, "vendor_signals is append-only; #destroy is not permitted"
  end

  def destroy!
    destroy
  end

  def delete
    raise AppendOnlyViolation, "vendor_signals is append-only; #delete is not permitted"
  end

  def update(attrs = {})
    guard_status_only!(attrs)
    super
  end

  def update!(attrs = {})
    guard_status_only!(attrs)
    super
  end

  # Insert (or re-fetch on dedup collision) a signal idempotently.
  # Returns the created row or the existing row with the matching dedup
  # tuple (tenant_id, source_system, source_event_id). The partition-key
  # constraint forces `recorded_at` into the unique index, so this method
  # also pre-checks the logical dedup key: if a row already exists with
  # the same (tenant, source_system, source_event_id), return it
  # unchanged (PRD §5.3 dedup step).
  def self.append!(attrs)
    tenant_id = attrs[:tenant_id] || attrs[:tenant]&.id
    source_system = attrs[:source_system]
    source_event_id = attrs[:source_event_id]

    if source_event_id.present?
      existing = where(tenant_id: tenant_id,
                       source_system: source_system,
                       source_event_id: source_event_id)
                   .order(recorded_at: :desc).first
      return existing if existing
    end

    create!(attrs)
  rescue ActiveRecord::RecordNotUnique
    where(
      tenant_id: tenant_id,
      source_system: source_system,
      source_event_id: source_event_id
    ).order(recorded_at: :desc).first
  end

  private

  def default_status
    self.status ||= "normalized"
  end

  # Allow #update only if the ONLY change is a legal status transition.
  # Any other field change is rejected as an AppendOnlyViolation.
  def guard_status_only!(attrs)
    attr_keys = attrs.keys.map(&:to_s)
    non_status = attr_keys - %w[status]

    if non_status.any?
      raise AppendOnlyViolation,
            "vendor_signals is append-only; only `status` may be updated (attempted: #{non_status.join(', ')})"
    end

    return unless attr_keys.include?("status")

    from = status
    to = attrs[:status] || attrs["status"]
    return if from == to

    allowed = STATUS_TRANSITIONS.fetch(from, [])
    unless allowed.include?(to)
      raise AppendOnlyViolation,
            "illegal status transition: #{from} -> #{to} (allowed: #{allowed.inspect})"
    end
  end
end
