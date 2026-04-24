# frozen_string_literal: true

# ActionPolicy for `Vendor`. Inherits `:user` (nullable) + `:tenant` from
# ApplicationPolicy. Every action permitted when `Current.tenant` is set;
# the middleware already guarantees that before the controller executes.
class VendorPolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
  alias_method :create?, :index?
  alias_method :update?, :index?
  alias_method :destroy?, :index?
end
