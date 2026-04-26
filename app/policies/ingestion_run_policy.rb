# frozen_string_literal: true

# ActionPolicy for `IngestionRun`. Read-only API surface — only index/show
# are exposed, both gated by tenant presence.
class IngestionRunPolicy < ApplicationPolicy
  def index?
    tenant.present?
  end
  alias_method :show?, :index?
end
