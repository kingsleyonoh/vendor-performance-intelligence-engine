# frozen_string_literal: true

# ActionPolicy for `AuditLogEntry`. Read-only surface — there is no
# create/update/destroy on this resource (insert-only at the model layer).
# Per Batch 007, the API-key holder IS the admin in v1, so any
# authenticated tenant can read its own audit rows. Cross-tenant scoping
# is enforced by the controller (404 on miss).
class AuditLogEntryPolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
end
