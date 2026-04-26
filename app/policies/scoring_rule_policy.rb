# frozen_string_literal: true

# ActionPolicy for `ScoringRule`. Inherits `:user` (nullable) + `:tenant`
# from ApplicationPolicy. Every action is permitted as long as
# `Current.tenant` is present — the middleware already enforces that.
class ScoringRulePolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
  alias_method :create?, :index?
  alias_method :update?, :index?
  alias_method :destroy?, :index?
  alias_method :activate?, :index?
  alias_method :preview?, :index?
end
