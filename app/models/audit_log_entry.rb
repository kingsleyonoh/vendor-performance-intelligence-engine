# frozen_string_literal: true

# AuditLogEntry — PRD §4.12. Insert-only audit trail for every mutating
# controller action and every mutating background job. tenant_id has NO
# foreign key constraint: audit rows MUST survive tenant deletion so
# post-deletion forensic queries are possible.
#
# At the application layer this is INSERT-only. The class method
# `.append!` is the single insert path. Any subsequent `save!`,
# `update!`, or `destroy!` on a persisted record raises
# `AuditLogEntry::ImmutableRecord`.
#
# The `Audit::Recorder` library wraps `.append!` and is the entry point
# every mutating controller / job uses. See
# `.agent/knowledge/foundation/audit-recorder.md`.
class AuditLogEntry < ApplicationRecord
  self.table_name = "audit_log_entries"

  class ImmutableRecord < StandardError; end

  belongs_to :tenant, optional: true

  validates :actor_type,  presence: true
  validates :action,      presence: true
  validates :entity_type, presence: true

  scope :recent, -> { order(occurred_at: :desc) }

  # Single INSERT entry point. Callers MUST use this instead of `.create!`
  # so we have one audited place where the row is materialized.
  def self.append!(
    tenant_id:,
    actor_type:,
    action:,
    entity_type:,
    actor_id: nil,
    entity_id: nil,
    before_state: nil,
    after_state: nil,
    metadata: {},
    occurred_at: Time.current
  )
    new(
      tenant_id: tenant_id,
      actor_type: actor_type,
      actor_id: actor_id,
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      before_state: before_state,
      after_state: after_state,
      metadata: metadata || {},
      occurred_at: occurred_at
    ).tap(&:save_new!)
  end

  # Internal — bypasses the immutability guard for the FIRST insert only.
  # Public API consumers must go through `.append!`.
  def save_new!
    raise ImmutableRecord, "AuditLogEntry rows are immutable; use .append!" if persisted?

    @inserting_via_append = true
    save!
  ensure
    @inserting_via_append = false
  end

  # ---------- Insert-only guards ----------
  def update(*)
    raise ImmutableRecord, "AuditLogEntry rows are insert-only (PRD §4.12)"
  end

  def update!(*)
    raise ImmutableRecord, "AuditLogEntry rows are insert-only (PRD §4.12)"
  end

  def save(*args, **kwargs)
    return super if @inserting_via_append || !persisted?

    raise ImmutableRecord, "AuditLogEntry rows are insert-only (PRD §4.12)"
  end

  def save!(*args, **kwargs)
    return super if @inserting_via_append || !persisted?

    raise ImmutableRecord, "AuditLogEntry rows are insert-only (PRD §4.12)"
  end

  def destroy
    raise ImmutableRecord, "AuditLogEntry rows are insert-only (PRD §4.12)"
  end

  def destroy!
    raise ImmutableRecord, "AuditLogEntry rows are insert-only (PRD §4.12)"
  end
end
