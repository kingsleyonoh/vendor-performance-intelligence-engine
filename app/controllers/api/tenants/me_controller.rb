# frozen_string_literal: true

module Api
  module Tenants
    # GET /api/tenants/me — PRD §8b.
    #
    # Returns the Alba-serialized Tenant for the caller's API key.
    # `Current.tenant` is set by `Auth::ApiKeyAuthenticator`; missing or
    # invalid keys are already 401'd by the middleware.
    class MeController < ::Api::BaseController
      def show
        render json: {
          tenant: TenantSerializer.new(Current.tenant).serializable_hash
        }, status: :ok
      end
    end
  end
end
