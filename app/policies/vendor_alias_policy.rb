# frozen_string_literal: true

# ActionPolicy for `VendorAlias`. See VendorPolicy.
class VendorAliasPolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
  alias_method :create?, :index?
  alias_method :update?, :index?
  alias_method :destroy?, :index?
  alias_method :pending?, :index?
end
