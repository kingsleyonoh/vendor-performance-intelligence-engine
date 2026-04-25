# frozen_string_literal: true

# ActionPolicy for `VendorReport`. Mirrors the project pattern — every
# action is permitted as long as `Current.tenant` is set; cross-tenant
# scoping is enforced by the controller (404 on miss).
class VendorReportPolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?,     :index?
  alias_method :create?,   :index?
  alias_method :download?, :index?
end
