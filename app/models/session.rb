# frozen_string_literal: true

# Session — Rails 8 built-in auth session row. Retrofitted with tenant_id
# in Batch 006 (security-audit H1) so the UI auth path pins Current.tenant
# from a single session-row read, not a User#tenant_id join.
class Session < ApplicationRecord
  belongs_to :user
  belongs_to :tenant

  before_validation :inherit_tenant_from_user, on: :create

  private

  def inherit_tenant_from_user
    self.tenant_id ||= user&.tenant_id
  end
end
