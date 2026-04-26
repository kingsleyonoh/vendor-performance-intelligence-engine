# frozen_string_literal: true

# ActionPolicy for `RiskAlert`. Mirrors VendorPolicy — every action is
# permitted as long as `Current.tenant` is set; tenant scoping is enforced
# by the controller via `tenant_scope`. Cross-tenant lookups never reach
# the policy because they 404 at `find`.
class RiskAlertPolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
  alias_method :acknowledge?, :index?
  alias_method :suppress?, :index?
  alias_method :retry?, :index?
end
