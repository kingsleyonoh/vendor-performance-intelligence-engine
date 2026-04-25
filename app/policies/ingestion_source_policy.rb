# frozen_string_literal: true

# ActionPolicy for `IngestionSource`. Same role model as ScoringRulePolicy:
# a present `Current.tenant` (set by ApiKeyAuthenticator) is sufficient —
# the API-key holder IS the operator (Batch 007 design decision).
class IngestionSourcePolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
  alias_method :create?, :index?
  alias_method :update?, :index?
  alias_method :destroy?, :index?
  alias_method :pull_now?, :index?
end
